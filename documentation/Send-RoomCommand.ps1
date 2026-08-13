<#
.SYNOPSIS
    Send room commands to a control processor's reboot listener or debug server.

.DESCRIPTION
    Both servers expose the same command set -- the reboot listener owns the
    registry and the debug server relays text into it -- but they are framed
    differently on the wire, which is what this script exists to hide:

        Listener (default port 3510)  plain lines, LF terminated
        Debug    (port 1988)          '<password>-<version>~END~' handshake first,
                                        then '~Room~:<command>~END~', each message
                                        terminated with a bare LF

    That LF is why telnet cannot drive the debug server: it sends CRLF, and the
    delimiter the processor looks for is '~END~' followed by LF alone.

    With no command, the script opens an interactive prompt against whichever
    server was chosen. Type 'help' for the command list, 'exit' to leave.

    Requires 'active_reboot_listener' (listener) or 'active_debug_server' (debug)
    to be true in the room's config.json. If 'reboot_listener_token' is set, pass
    it with -Token; it is applied on both servers.

.PARAMETER Address
    Hostname or IP of the control processor.

.PARAMETER Command
    The command to run, e.g. 'power list' or 'power Power1-outlet-1-PC on'.
    Trailing words are joined, so quoting is optional. Omit for interactive mode.

.PARAMETER Server
    'Listener' (default) or 'Debug'.

.PARAMETER Port
    Overrides the default port for the chosen server (3510 / 1988).

.PARAMETER Token
    Value of 'reboot_listener_token' when the room has one configured.

.PARAMETER Password
    Debug-server handshake password. Defaults to the stock DebugServer password;
    override when the room sets 'reboot_listener_client_password'.

.PARAMETER Raw
    Print everything the server sends instead of just the command replies.
    Useful when a debug-server session is not behaving.

.EXAMPLE
    .\Send-RoomCommand.ps1 10.0.0.5 power list

.EXAMPLE
    .\Send-RoomCommand.ps1 10.0.0.5 power Power1-outlet-1-PC on

.EXAMPLE
    .\Send-RoomCommand.ps1 10.0.0.5 power Power1-outlet-8-USB-Switch reboot
    Power-cycles one outlet. 'power list' shows each target's accepted verbs in
    brackets -- a leg configured reboot-only shows [reboot] and refuses on/off.

.EXAMPLE
    .\Send-RoomCommand.ps1 10.0.0.5 -Server Debug action startup

.EXAMPLE
    .\Send-RoomCommand.ps1 10.0.0.5 reboot program
    Restarts the control script only. 'reboot processor' restarts the whole
    device and takes minutes; this takes seconds.

.EXAMPLE
    .\Send-RoomCommand.ps1 10.0.0.5 timer event
    Switches the inactivity timer to Event (6hr) and reports where it landed.
    'timer list' names the modes, 'timer' alone reports the current one.

.EXAMPLE
    .\Send-RoomCommand.ps1 10.0.0.5 -Token s3cret
    Interactive prompt against the listener on a room that requires a token.

.NOTES
    Windows PowerShell 5.1 compatible. See
    base/assets/src/modules/project/reboot_listener.py for the wire protocol and
    the full command list.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Address,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Command,

    [ValidateSet('Listener', 'Debug')]
    [string]$Server = 'Listener',

    [int]$Port = 0,

    [string]$Token = '',

    [string]$Password = 'p9oai23jr09p8fmvw98foweivmawthapw4t',

    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$ClientVersion = '1.9.0.0',

    [int]$TimeoutMs = 5000,

    [switch]$Raw
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$DEBUG_DELIM = '~END~'
$ROOM_REPLY = '~RoomReply~:'

if ($Port -le 0) {
    if ($Server -eq 'Debug') { $Port = 1988 } else { $Port = 3510 }
}

function Read-Available {
    <#
        Collect whatever arrives, then stop once the socket has been quiet for
        QuietMs. The servers answer one command with several lines, so returning
        on the first read would truncate a 'status' or 'power list' reply.
    #>
    param(
        [Parameter(Mandatory = $true)]$Stream,
        [int]$QuietMs = 400,
        [int]$Timeout = 5000
    )

    $text = New-Object System.Text.StringBuilder
    $buffer = New-Object byte[] 8192
    $deadline = (Get-Date).AddMilliseconds($Timeout)
    $lastData = Get-Date

    while ((Get-Date) -lt $deadline) {
        if ($Stream.DataAvailable) {
            $count = $Stream.Read($buffer, 0, $buffer.Length)
            if ($count -gt 0) {
                [void]$text.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $count))
                $lastData = Get-Date
            }
        }
        else {
            $idleMs = ((Get-Date) - $lastData).TotalMilliseconds
            if ($text.Length -gt 0 -and $idleMs -ge $QuietMs) { break }
            Start-Sleep -Milliseconds 50
        }
    }

    return $text.ToString()
}

function Get-ReplyLines {
    <#
        Listener replies are CRLF-terminated lines. Debug replies are wrapped in
        '~RoomReply~:...~END~' and share the socket with registration traffic the
        caller did not ask for, so everything else is dropped unless -Raw.
    #>
    param(
        [string]$Text,
        [string]$Kind,
        [switch]$IncludeAll
    )

    if ([string]::IsNullOrEmpty($Text)) { return @() }
    if ($IncludeAll) { return @($Text -split "\r?\n" | Where-Object { $_ -ne '' }) }

    # TrimEnd, never Trim: 'help' indents its command families, and trimming the
    # front would flatten that back out.
    if ($Kind -eq 'Debug') {
        $lines = @()
        foreach ($chunk in ($Text -split [regex]::Escape($DEBUG_DELIM))) {
            $index = $chunk.IndexOf($ROOM_REPLY)
            if ($index -ge 0) {
                $lines += $chunk.Substring($index + $ROOM_REPLY.Length).TrimEnd()
            }
        }
        return $lines
    }

    return @($Text -split "\r?\n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
}

function Send-Text {
    param(
        [Parameter(Mandatory = $true)]$Writer,
        [Parameter(Mandatory = $true)][string]$Text
    )
    # Bare LF, never CRLF: the debug server's delimiter is '~END~' + LF, and the
    # listener strips a stray CR but has no reason to receive one.
    $Writer.Write($Text + "`n")
}

function Invoke-RoomCommand {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)]$Writer,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $line = $Text
    if ($Token -ne '') { $line = "$Token $line" }

    if ($Server -eq 'Debug') {
        Send-Text -Writer $Writer -Text ("~Room~:" + $line + $DEBUG_DELIM)
    }
    else {
        Send-Text -Writer $Writer -Text $line
    }

    # Not $raw: variable names are case-insensitive, so that would shadow the
    # -Raw switch on the very next line.
    $response = Read-Available -Stream $Client.GetStream() -Timeout $TimeoutMs
    return Get-ReplyLines -Text $response -Kind $Server -IncludeAll:$Raw
}

$client = $null
try {
    Write-Verbose "Connecting to $Address`:$Port ($Server)"
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($Address, $Port)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    if ($Server -eq 'Debug') {
        # The version suffix is compared part by part against a 4-part minimum,
        # so it must be >= 1.8.0.0 and must itself have four parts -- hence the
        # pattern on the parameter. A short one walks off the end of the split on
        # the processor rather than failing cleanly.
        Send-Text -Writer $writer -Text ("$Password-$ClientVersion" + $DEBUG_DELIM)
        $login = Read-Available -Stream $stream -Timeout $TimeoutMs
        if ($login -match 'Version Check Failure') {
            throw "Debug server rejected the client version '$ClientVersion' (needs 1.8.0.0 or newer)."
        }
        if ([string]::IsNullOrEmpty($login)) {
            throw "No response to the debug handshake. Check the password and that 'active_debug_server' is true."
        }
        Write-Verbose 'Debug handshake accepted.'
    }

    $commandText = ''
    if ($null -ne $Command) { $commandText = ($Command -join ' ').Trim() }

    if ($commandText -ne '') {
        Invoke-RoomCommand -Client $client -Writer $writer -Text $commandText
    }
    else {
        # Read-Host against redirected input returns empty forever rather than
        # blocking, which would spin this loop, so refuse up front and say what
        # to do instead.
        if ([Console]::IsInputRedirected) {
            throw "Interactive mode needs a console. Pass the command as arguments instead, e.g. .\Send-RoomCommand.ps1 $Address power list"
        }

        Write-Host "Connected to $Address`:$Port ($Server). 'help' for commands, 'exit' to quit." -ForegroundColor Cyan
        while ($true) {
            # Not $input: that name is the pipeline enumerator PowerShell defines
            # for us, and writing to it is asking for trouble.
            $entry = Read-Host 'room'
            if ($null -eq $entry) { break }
            $entry = $entry.Trim()
            if ($entry -eq '') { continue }
            if (@('exit', 'quit', 'close') -contains $entry) {
                # Sent as well as acted on locally: the listener closes the
                # socket on 'exit', and the debug server keeps it open, so the
                # loop has to end either way.
                Invoke-RoomCommand -Client $client -Writer $writer -Text $entry
                break
            }
            Invoke-RoomCommand -Client $client -Writer $writer -Text $entry
        }
    }
}
catch [System.Net.Sockets.SocketException] {
    Write-Error "Cannot reach $Address`:$Port -- $($_.Exception.Message)"
    exit 1
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($null -ne $client) { $client.Close() }
}
