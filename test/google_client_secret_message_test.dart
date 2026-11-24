import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/google_sheets_export.dart';
import 'package:extron_configurator/save_actions.dart'
    show onlineCopyFailedMessage;
import 'package:extron_configurator/secret_store.dart';

/// A Google client with an ID and no secret says so, rather than "not signed
/// in"; and only files are called open or locked after a save.
void main() {
  test('no client secret names the missing secret', () async {
    final uploader = GoogleSheetsUploader(
      clientId: 'id.apps.googleusercontent.com',
      clientSecret: '',
      secrets: InMemorySecretStore({kGoogleRefreshTokenKey: 'old'}),
      openUrl: (_) async => fail('no browser without a secret'),
    );
    for (final interactive in [false, true]) {
      await expectLater(
        uploader.accessToken(interactive: interactive),
        throwsA(
          isA<GoogleSheetsException>().having(
            (e) => e.message,
            'message',
            kGoogleNoSecretMessage,
          ),
        ),
      );
    }
  });

  test('save note: the Sheet is never "open or locked"', () {
    expect(
      onlineCopyFailedMessage(['Google Sheet']),
      'The Google Sheet was not updated. See the log.',
    );
    expect(
      onlineCopyFailedMessage(['job.xlsx']),
      'Online copy not updated - job.xlsx is open or locked. See the log.',
    );
    expect(
      onlineCopyFailedMessage(['Google Sheet', 'job.xlsx']),
      'Online copy not updated - the Google Sheet failed and job.xlsx is '
      'open or locked. See the log.',
    );
  });
}
