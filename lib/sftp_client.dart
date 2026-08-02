import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';

// [LOGIC - CONFIG]: Enum to differentiate what we want to pull from the Extron processor
enum LogFileType { debug, program }

// [LOGIC - NETWORK / FILE I/O]: Handles secure SSH/SFTP connections to Extron processors
// to download and process historical debug logs stored on the hardware.
class SftpLogger {
  // [LOGIC - PARSING]: Standard Extron debug logs follow this naming convention.
  // This regex extracts the Year, Month, Day, and Hour for date filtering.
  final RegExp _debugFileRegex =
      RegExp(r'DebugLog-(\d{4})-(\d{2})-(\d{2})-(\d{2})\.csv');

  // [LOGIC - PARSING]: Program logs (system errors, Python prints) follow this naming convention.
  // Extracts Year, Month, Day, Hour, Minute, and Second.
  final RegExp _programFileRegex = RegExp(
      r'ProgramLog-(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})\.log');

  // [LOGIC - CORE]: The primary method that orchestrates the connection, directory listing,
  // date filtering, downloading, and merging of multiple files into a single local file.
  Future<bool> pullAndCombineLogs({
    required String ipAddress,
    required String password,
    required String outputPath,
    required Function(String) onStatusUpdate,
    bool Function()? cancelCheck,
    DateTime? startDate,
    DateTime? endDate,
    LogFileType logType = LogFileType
        .debug, // [LOGIC - CONFIG]: Defaults to existing CSV debug log behavior
    String username = 'admin', // Extron standards; overridable in App Config
    int port = 22022,
  }) async {
    try {
      onStatusUpdate('System: Connecting to SFTP on $ipAddress:$port...');

      // [LOGIC - NETWORK]: Establishes the underlying SSH socket. Extron uses port 22022 for secure file transfer.
      final client = SSHClient(
        await SSHSocket.connect(ipAddress, port,
            timeout: const Duration(seconds: 10)),
        username: username, // [LOGIC - AUTH]: Standard Extron admin user
        onPasswordRequest: () => password,

        // [LOGIC - AUTH]: Extron processors often use "keyboard-interactive" authentication.
        // This intercepts any prompts from the server and automatically feeds it the admin password.
        onUserInfoRequest: (request) {
          // The 'request' object contains a list of prompts.
          // We respond to every prompt the processor asks with the password.
          return request.prompts.map((_) => password).toList();
        },
      );

      // [LOGIC - NETWORK]: Upgrades the SSH session to an SFTP subsystem channel.
      final sftp = await client.sftp();

      // [LOGIC - ROUTING]: Dynamically route to the correct folder and regex based on requested log type
      String remoteDir =
          logType == LogFileType.debug ? '/DebugLogs/' : '/ProgramLogs/';
      RegExp activeRegex =
          logType == LogFileType.debug ? _debugFileRegex : _programFileRegex;

      onStatusUpdate('System: Pulling file list from $remoteDir...');

      // [LOGIC - NETWORK]: Fetches the metadata (name, size, permissions) for all files in the directory.
      final items = await sftp.listdir(remoteDir);

      // [LOGIC - DATA FILTERING]: Iterates through the remote files to find valid files
      // that fall within the user's selected date range.
      final targetFiles = items.where((item) {
        // Ensure grabbing the correct extension
        if (logType == LogFileType.debug && !item.filename.endsWith('.csv')) {
          return false;
        }
        if (logType == LogFileType.program && !item.filename.endsWith('.log')) {
          return false;
        }

        // If the user selected "All Time" in the UI, grab everything.
        if (startDate == null && endDate == null) return true;

        final match = activeRegex.firstMatch(item.filename);
        if (match == null) return false;

        // [LOGIC - PARSING]: Extract date components based on the regex
        int year = int.parse(match.group(1)!);
        int month = int.parse(match.group(2)!);
        int day = int.parse(match.group(3)!);
        int hour = int.parse(match.group(4)!);

        DateTime fileDate = DateTime(year, month, day, hour);

        // Discard files outside the target window
        if (startDate != null && fileDate.isBefore(startDate)) return false;
        if (endDate != null &&
            fileDate
                .isAfter(endDate.add(const Duration(hours: 23, minutes: 59)))) {
          return false;
        }

        return true;
      }).toList();

      // [LOGIC - DATA]: Sort files chronologically so the final merged file is in perfect time order.
      targetFiles.sort((a, b) => a.filename.compareTo(b.filename));

      if (targetFiles.isEmpty) {
        onStatusUpdate(
            'System: No files found in $remoteDir for the selected date range.');
        client.close();
        return false;
      }

      // [LOGIC - FILE I/O]: Opens a continuous write stream to the user's selected local save location.
      final outputFile = File(outputPath);
      final sink = outputFile.openWrite();
      int count = 1;

      for (var file in targetFiles) {
        if (cancelCheck != null && cancelCheck()) {
          onStatusUpdate('System: Download aborted by user.');

          // Clean up resources immediately to prevent memory leaks and locked files
          await sink.flush();
          await sink.close();
          client.close();

          // Optional: Delete the partially downloaded file so you don't leave broken files behind
          if (await outputFile.exists()) {
            await outputFile.delete();
          }

          return false; // Exit the function cleanly
        }
        onStatusUpdate(
            'System: Downloading file $count of ${targetFiles.length} (${file.filename})...');

        // [LOGIC - NETWORK & MEMORY]: Opens the remote file and reads it directly into memory as bytes.
        final remoteFile = await sftp.open('$remoteDir${file.filename}');
        final contentBytes = await remoteFile.readBytes();
        final contentString = utf8.decode(contentBytes);

        // [LOGIC - PARSING]: Splits the file string into individual lines for header management.
        List<String> lines = const LineSplitter().convert(contentString);
        if (lines.isNotEmpty) {
          if (logType == LogFileType.debug) {
            if (count == 1) {
              // Keep the header row for the very first file
              sink.writeAll(lines, '\n');
            } else {
              // [LOGIC - DATA]: Skip the first line (header) for all subsequent files so the CSV stays clean
              sink.writeAll(lines.skip(1), '\n');
            }
          } else {
            // [LOGIC - DATA]: Program logs are raw text without headers, concatenate them all directly
            sink.writeAll(lines, '\n');
          }
          sink.write('\n'); // Ensure proper spacing between concatenated files
        }
        count++;
      }

      onStatusUpdate('System: Combining downloaded files...');

      // [LOGIC - FILE I/O]: Ensures all data is committed to disk and resources are released.
      await sink.flush();
      await sink.close();
      client.close(); // Kills the SSH socket

      onStatusUpdate('System: Download complete. File saved to $outputPath');
      return true;
    } catch (e) {
      onStatusUpdate('System Error: Failed to pull logs - $e');
      return false;
    }
  }

  // [LOGIC - FILE I/O]: Downloads a specific file from the processor's root directory
  Future<bool> downloadProcessorFile({
    required String ipAddress,
    required String password,
    required String remoteFilename, // e.g., '/config.json'
    required String outputPath,
    required Function(String) onStatusUpdate,
    String username = 'admin', // Extron standards; overridable in App Config
    int port = 22022,
  }) async {
    try {
      onStatusUpdate('System: Connecting to SFTP on $ipAddress:$port...');
      final client = SSHClient(
        await SSHSocket.connect(ipAddress, port, timeout: const Duration(seconds: 10)),
        username: username,
        onPasswordRequest: () => password,
        onUserInfoRequest: (request) => request.prompts.map((_) => password).toList(),
      );
      
      final sftp = await client.sftp();
      final remoteFile = await sftp.open(remoteFilename);
      final contentBytes = await remoteFile.readBytes();
      await File(outputPath).writeAsBytes(contentBytes);
      
      client.close();
      onStatusUpdate('System: Download complete. Saved to $outputPath');
      return true;
    } catch (e) {
      onStatusUpdate('System Error: Failed to download $remoteFilename - $e');
      return false;
    }
  }

  // [LOGIC - FILE I/O]: Uploads ANY selected file to the processor's root directory
  Future<bool> uploadFileToProcessor({
    required String ipAddress,
    required String password,
    required String inputPath,
    required String remoteFilename, // e.g., '/Whereused.csv' or '/config.json'
    required Function(String) onStatusUpdate,
    String username = 'admin', // Extron standards; overridable in App Config
    int port = 22022,
  }) async {
    try {
      onStatusUpdate('System: Connecting to SFTP on $ipAddress:$port...');
      final client = SSHClient(
        await SSHSocket.connect(ipAddress, port, timeout: const Duration(seconds: 10)),
        username: username,
        onPasswordRequest: () => password,
        onUserInfoRequest: (request) => request.prompts.map((_) => password).toList(),
      );
      
      final sftp = await client.sftp();
      final file = File(inputPath);
      final bytes = await file.readAsBytes();
      
      // Attempt to remove the old file before overwriting to bypass permission lockups
      try { await sftp.remove(remoteFilename); } catch (_) {}
      
      final remoteFile = await sftp.open(remoteFilename, mode: SftpFileOpenMode.create | SftpFileOpenMode.write);
      await remoteFile.writeBytes(bytes);
      
      client.close();
      onStatusUpdate('System: Upload complete. Wrote $remoteFilename');
      return true;
    } catch (e) {
      onStatusUpdate('System Error: Failed to upload $remoteFilename - $e');
      return false;
    }
  }

  // [LOGIC - FILE I/O]: Deletes a specific file from the root directory
  Future<bool> deleteProcessorFile({
    required String ipAddress,
    required String password,
    required String remoteFilename, // e.g., '/config.json'
    required Function(String) onStatusUpdate,
    String username = 'admin', // Extron standards; overridable in App Config
    int port = 22022,
  }) async {
    try {
      onStatusUpdate('System: Connecting to SFTP on $ipAddress:$port...');
      final client = SSHClient(
        await SSHSocket.connect(ipAddress, port, timeout: const Duration(seconds: 10)),
        username: username,
        onPasswordRequest: () => password,
        onUserInfoRequest: (request) => request.prompts.map((_) => password).toList(),
      );
      
      final sftp = await client.sftp();
      await sftp.remove(remoteFilename);
      
      client.close();
      onStatusUpdate('System: Deleted $remoteFilename');
      return true;
    } catch (e) {
      onStatusUpdate('System Error: Failed to delete $remoteFilename - $e');
      return false;
    }
  }
}