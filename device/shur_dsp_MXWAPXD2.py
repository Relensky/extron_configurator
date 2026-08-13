# pylint: disable=consider-using-f-string
# pylint: disable=C0111,C0302
# pylint: disable=invalid-name
# pylint: disable=missing-module-docstring
# pylint: disable=missing-class-docstring
# pylint: disable=missing-function-docstring
import re
from extronlib.interface import EthernetClientInterface
from extronlib.system import Wait, ProgramLog


# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "dsp",
    "models": ["MXWAPXD2"],
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 2202,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",  # site-specific — blank
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_DSP1",
        "lbl_name": "Lbl_DSP_Name_Status",
        "gve_id": "DSP1",
        "name": "DSP - MXWAPXD2",
        "keep_alive_command": "SerialNumber",
        "keep_alive_interval": 30,
        "keep_alive_trigger": None,
        "manual_disconnect": False,
        "user": "",
        "password": "ATEC2008",
    },
    # How this driver is reached on each connection style, read by the app:
    # changing com_type loads the matching block, and picking a model merges it
    # over "connection" + "defaults". Ports are the ones the module's
    # communication sheet documents; protocol, baud and service port are the
    # defaults declared by the wrapper classes at the bottom of this file.
    "network": {
        "protocol": "TCP",
        "net_port": 2202,
        "service_port": 0,
    },
}


class DeviceClass:
    def __init__(self):

        self.Unidirectional = "False"
        self.connectionCounter = 15
        self.DefaultResponseTimeout = 0.3
        self.Subscription = {}
        self.ReceiveData = self.__ReceiveData
        self.__receiveBuffer = b""
        self.__maxBufferSize = 2048
        self.__matchStringDict = {}
        self.counter = 0
        self.connectionFlag = True
        self.initializationChk = True
        self.Debug = False
        self.Models = {}
        self.SetChannelStates = {
            "1": "1",
            "2": "2",
            "3": "3",
            "4": "4",
            "5": "5",
            "6": "6",
            "All": "0",
        }

        self.Commands = {
            "ConnectionStatus": {"Status": {}},
            "Reboot": {"Status": {}},
            "AllCheck": {"Status": {}},
            "AudioGain": {"Parameters": ["Channel"], "Status": {}},
            "SystemPresetMode": {"Status": {}, 'AllowedValues': ['Presentation', 'Direct', 'Conference', 'Custom']},
            "DeviceID": {"Status": {}},
            "TXDeviceID": {"Parameters": ["Channel"], "Status": {}},
            "BAYDeviceID": {"Parameters": ["Channel"], "Status": {}},
            "MicrophoneType": {"Parameters": ["Channel"], "Status": {}},
            "TransmitterStatus": {"Parameters": ["Channel"], "Status": {}},
            "ChargeBay": {"Parameters": ["Channel"], "Status": {}},
            "SerialNumber": {"Status": {}},
        }

        if self.Unidirectional == "False":
            self.AddMatchString(
                re.compile(
                    b"< REP (?P<channel>[1-6]) INPUT_CH_GAIN (?P<gain>\d{1,3}|1[0-3]\d{2}|1400|\d) >"
                ),
                self.__MatchAudioGain,
                None,
            )
            self.AddMatchString(
                re.compile(b"< REP SYSTEM_PRESET_MODE (?P<mode>\w+) >"),
                self.__MatchSystemPresetMode,
                None,
            )
            self.AddMatchString(
                re.compile(b"< REP DEVICE_ID {([A-Za-z0-9 -]{1,100})(?:\s+)} >"),
                self.__MatchDeviceID,
                None,
            )
            self.AddMatchString(
                re.compile(
                    b"< REP CH (?P<channel>[12]) TX_DEVICE_ID {([^}]+)} >"
                ),
                self.__MatchTXDeviceID,
                None,
            )
            self.AddMatchString(
                re.compile(
                    b"< REP BAY (?P<channel>[12]) TX_DEVICE_ID {([^}]+)} >"
                ),
                self.__MatchBAYDeviceID,
                None,
            )
            self.AddMatchString(
                re.compile(b"< REP SERIAL_NUM {([A-Za-z0-9]+)} >"),
                self.__MatchSerialNumber,
                None,
            )
            self.AddMatchString(
                re.compile(
                    b"< REP (?P<channel>[1-8]) TX_TYPE (?P<type>MXW1|MXW2|MXW6|MXW8|UNKNOWN) >"
                ),
                self.__MatchMicrophoneType,
                None,
            )
            self.AddMatchString(
                re.compile(
                    b"< REP CH (?P<channel>1|2) TX_STATUS (?P<status>ACTIVE|MUTED|STANDBY|ON_CHARGER|UNKNOWN) >"
                ),
                self.__MatchTransmitterStatus,
                None,
            )
            self.AddMatchString(
                re.compile(
                    b"< REP BAY (?P<channel>1|2) TX_STATUS (?P<status>ACTIVE|MUTED|STANDBY|ON_CHARGER|UNKNOWN) >"
                ),
                self.__MatchChargeBay,
                None,
            )
            self.AddMatchString(re.compile(b"< REP ERR >"), self.__MatchError, "ERR")
            self.AddMatchString(
                re.compile(
                    b"< REP (?P<channel>[1-6]) (?P<command>[A-Z_]{1,10}) (?P<code>252|253|254|255|65535|65534|65533|65532|ERR) >"
                ),
                self.__MatchError,
                "EXTRA",
            )

            self.LastUpdateTime = {
                "AudioGain": 0,
                "SystemPresetMode": 0,
                "MicrophoneType": 0,
                "DeviceID": 0,
                "TXDeviceID": 0,
                "BAYDeviceID": 0,
                "TransmitterStatus": 0,
                "ChargeBay": 0,
            }

    def SetReboot(self, value, qualifier):
        RebootCmdString = "< SET REBOOT >"
        print("Reboot called {}".format(RebootCmdString))
        self.__SetHelper("Reboot", RebootCmdString, value, None)

    def SetAllCheck(self, value, qualifier):
        AllCheckCmdString = "< GET ALL >"
        print("AllCheck called {}".format(AllCheckCmdString))
        self.__SetHelper("AllCheck", AllCheckCmdString, value, None)

    def SetAudioGain(self, value, qualifier):
        result = value * 10 + 1100
        if 0 <= result <= 1400:
            AudioGainCmdString = "< SET {0} INPUT_CH_GAIN {1} >".format(
                qualifier["Channel"], result
            )
            self.__SetHelper("AudioGain", AudioGainCmdString, value, qualifier)
            print(
                "Audio Gain Set string{} ch {} gain {}".format(
                    AudioGainCmdString, qualifier, value
                )
            )
        else:
            self.Discard("Invalid Command for SetAudioGain")

    def UpdateAudioGain(self, value, qualifier):
        if (
            not qualifier["Channel"] == "All"
            and qualifier["Channel"] in self.SetChannelStates
        ):
            AudioGainCmdString = "< GET {0} INPUT_CH_GAIN >".format(
                self.SetChannelStates[qualifier["Channel"]]
            )
        else:
            AudioGainCmdString = "< GET 0 INPUT_CH_GAIN >"
            self.__UpdateHelper("AudioGain", AudioGainCmdString, value, qualifier)
        print(
            "Audio Gain Update String {} ch {}".format(
                AudioGainCmdString, qualifier
            )
        )

    def __MatchAudioGain(self, match, tag):
        channel = match.group("channel").decode()
        gain = int(match.group("gain").decode())
        value = (gain - 1100) / 10
        print("Audio Gain found ch {} gain {}".format(channel, value))
        qualifier = {"Channel": channel}
        self.WriteStatus("AudioGain", value, qualifier)


    def SetSystemPresetMode(self, value, qualifier):

        ValueStateValues = {
            "Presentation": "PRESENTATION",
            "Direct": "DIRECT",
            "Conference": "CONFERENCE",
            "Custom": "CUSTOM",
        }

        if value in ValueStateValues:
            SystemPresetModeCmdString = "< SET SYSTEM_PRESET_MODE {} >".format(
                ValueStateValues[value]
            )
            self.__SetHelper("SystemPresetMode", SystemPresetModeCmdString, value, None)
        else:
            self.Discard("Invalid Command for SetSystemPresetMode")

    def UpdateSystemPresetMode(self, value, qualifier):
        SystemPresetModeCmdString = "< GET SYSTEM_PRESET_MODE >"
        print("Preset Mode Update Sent {}".format(SystemPresetModeCmdString))
        self.__UpdateHelper("SystemPresetMode", SystemPresetModeCmdString, value, None)

    def __MatchSystemPresetMode(self, match, tag):
        value = match.group(1).decode()
        print("System Preset Mode Found {}".format(value))
        self.WriteStatus("SystemPresetMode", value, None)

    def SetDeviceID(self, value, qualifier):
        # Check if the length is between 1 to 12 characters
        if 1 <= len(value) <= 12:
            # Check if the string consists of only alphanumeric characters and hyphens
            if re.match(r"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$", value):
                # Check if it does not begin or end with a hyphen
                if not value.startswith("-") and not value.endswith("-"):
                    DeviceIDCmdString = "< SET DEVICE_ID {{{}}} >".format(value)
                    self.__SetHelper("DeviceID", DeviceIDCmdString, value, None)
        else:
            self.Discard("Invalid Command for SetDeviceID")

    def UpdateDeviceID(self, value, qualifier):
        print("Device ID Update Called")
        DeviceIDCmdString = "< GET DEVICE_ID >"
        print(DeviceIDCmdString)
        self.__UpdateHelper("DeviceID", DeviceIDCmdString, value, None)

    def __MatchDeviceID(self, match, tag):

        value = match.group(1).decode()
        self.WriteStatus("DeviceID", value, None)
        print("Device ID Found {}".format(value))

    def SetTXDeviceID(self, value, qualifier):
        # Check if the length is between 1 to 12 characters
        if 1 <= len(value) <= 12:
            # Check if the string consists of only alphanumeric characters and hyphens
            if re.match(r"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$", value):
                # Check if it does not begin or end with a hyphen
                if not value.startswith("-") and not value.endswith("-"):
                    TXDeviceIDCmdString = "< SET CH {} TX_DEVICE_ID {{{}}} >".format(
                        self.SetChannelStates[qualifier["Channel"]],
                        value,
                    )
                    self.__SetHelper(
                        "TXDeviceID", TXDeviceIDCmdString, value, qualifier
                    )
        else:
            self.Discard("Invalid Command for SetDeviceID")

    def UpdateTXDeviceID(self, value, qualifier):

        DeviceIDCmdString = "< GET CH 0 TX_DEVICE_ID >"
        self.__UpdateHelper("TXDeviceID", DeviceIDCmdString, value, qualifier)

    def __MatchTXDeviceID(self, match, tag):

        qualifier = {"Channel": match.group("channel").decode()}
        value = match.group(2).decode()  # Use match.group(2) to capture the device ID string
        self.WriteStatus("TXDeviceID", value, qualifier)
        print("Match TX Device ID: {}, {}".format(value, qualifier))

    def SetBAYDeviceID(self, value, qualifier):
        # Check if the length is between 1 to 12 characters
        if 1 <= len(value) <= 12:
            # Check if the string consists of only alphanumeric characters and hyphens
            if re.match(r"^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$", value):
                # Check if it does not begin or end with a hyphen
                if not value.startswith("-") and not value.endswith("-"):
                    BAYDeviceIDCmdString = "< SET BAY {} TX_DEVICE_ID {{{}}} >".format(
                        self.SetChannelStates[qualifier["Channel"]],
                        value,
                    )
                    self.__SetHelper(
                        "BAYDeviceID", BAYDeviceIDCmdString, value, qualifier
                    )
        else:
            self.Discard("Invalid Command for SetDeviceID")

    def UpdateBAYDeviceID(self, value, qualifier):

        DeviceIDCmdString = "< GET BAY 0 TX_DEVICE_ID >"
        self.__UpdateHelper("BAYDeviceID", DeviceIDCmdString, value, qualifier)

    def __MatchBAYDeviceID(self, match, tag):

        qualifier = {"Channel": match.group("channel").decode()}
        value = match.group(2).decode()  # Use match.group(2) to capture the device ID string
        self.WriteStatus("BAYDeviceID", value, qualifier)
        print("Match BAY Device ID: {}, {}".format(value, qualifier))

    def UpdateSerialNumber(self, value, qualifier):

        SerialNumberCmdString = "< GET SERIAL_NUM >"
        self.__UpdateHelper("SerialNumber", SerialNumberCmdString, value, qualifier)

    def __MatchSerialNumber(self, match, tag):

        value = match.group(1).decode()
        self.WriteStatus("SerialNumber", value, None)

    def UpdateMicrophoneType(self, value, qualifier):

        if qualifier["Channel"] in self.SetChannelStates:
            MicrophoneTypeCmdString = "< GET 0 TX_TYPE >"
            self.__UpdateHelper(
                "MicrophoneType", MicrophoneTypeCmdString, value, qualifier
            )
        else:
            self.Discard("Device Is Busy for UpdateMicrophoneType")

    def __MatchMicrophoneType(self, match, tag):

        ValueStateValues = {
            "MXW1X": "MXW1X",
            "MXW2X": "MXW2X",
            "MXW6X": "MXW6X",
            "UNKNOWN": "Unknown",
        }

        qualifier = {"Channel": match.group("channel").decode()}
        value = ValueStateValues[match.group("type").decode()]
        self.WriteStatus("MicrophoneType", value, qualifier)

    def SetTransmitterStatus(self, value, qualifier):
        if value not in ["MUTED", "ACTIVE"]:
            self.Discard("Invalid Command for SetTransmitterStatus")
        else:
            TransmitterStatusCmdString = "< SET CH {} TX_STATUS {} >".format(
                self.SetChannelStates[qualifier["Channel"]],
                value,
            )
            self.__SetHelper(
                "TransmitterStatus", TransmitterStatusCmdString, value, qualifier
            )

    def UpdateTransmitterStatus(self, value, qualifier):

        TransmitterStatusCmdString = "< GET CH 0 TX_STATUS >"
        self.__UpdateHelper(
            "TransmitterStatus", TransmitterStatusCmdString, value, qualifier
        )


    def __MatchTransmitterStatus(self, match, tag):

        ValueStateValues = {
            'ACTIVE'        : 'Active', 
            'MUTED'         : 'Muted', 
            'STANDBY'       : 'Standby', 
            'UNKNOWN'       : 'Disconnected', 
            'ON_CHARGER'    : 'On Charger'
        }

        qualifier = {'Channel': match.group('channel').decode()}
        value = ValueStateValues[match.group('status').decode()]
        self.WriteStatus('TransmitterStatus', value, qualifier)
        print("Transmitter Status Match {} {}".format(value, qualifier))


    def UpdateChargeBay(self, value, qualifier):

        ChargeBayCmdString = "< GET BAY 0 TX_STATUS >"
        self.__UpdateHelper(
            "ChargeBay", ChargeBayCmdString, value, qualifier
        )

    def __MatchChargeBay(self, match, tag):

        ValueStateValues = {
            'ACTIVE'        : 'Active', 
            'MUTED'         : 'Muted', 
            'STANDBY'       : 'Standby', 
            'UNKNOWN'       : 'Empty', 
            'ON_CHARGER'    : 'On Charger'
        }

        qualifier = {'Channel': match.group('channel').decode()}
        value = ValueStateValues[match.group('status').decode()]
        self.WriteStatus("ChargeBay", value, qualifier)
        print("ChargeBay Status Match {} {}".format(value, qualifier))


    def __SetHelper(self, command, commandstring, value, qualifier):
        self.Debug = True
        self.Send(commandstring)

    def __UpdateHelper(self, command, commandstring, value, qualifier):

        if self.Unidirectional == "True":
            self.Discard("Inappropriate Command " + command)
        else:
            if self.initializationChk:
                self.OnConnected()
                self.initializationChk = False

            self.counter = self.counter + 1
            if self.counter > self.connectionCounter and self.connectionFlag:
                self.OnDisconnected()

            self.Send(commandstring)

    def __MatchError(self, match, tag):
        self.counter = 0

        if tag == "ERR":
            self.Error(["Command is not able to be implemented"])
        elif tag == "EXTRA":
            self.Error(
                [
                    "Error Channel: {0} Command: {1} Code: {2}".format(
                        match.group("channel").decode(),
                        match.group("command").decode(),
                        match.group("code").decode(),
                    )
                ]
            )

    def OnConnected(self):
        self.connectionFlag = True
        self.WriteStatus("ConnectionStatus", "Connected")
        self.counter = 0

    def OnDisconnected(self):
        self.WriteStatus("ConnectionStatus", "Disconnected")
        self.connectionFlag = False

    ######################################################
    # RECOMMENDED not to modify the code below this point
    ######################################################

    # Send Control Commands
    def Set(self, command, value, qualifier=None):
        method = getattr(self, "Set%s" % command, None)
        if method is not None and callable(method):
            method(value, qualifier)
        else:
            raise AttributeError(command + "does not support Set.")

    # Send Update Commands
    def Update(self, command, qualifier=None):
        method = getattr(self, "Update%s" % command, None)
        if method is not None and callable(method):
            method(None, qualifier)
        else:
            raise AttributeError(command + "does not support Update.")

    # This method is to tie an specific command with a parameter to a call back method
    # when its value is updated. It sets how often the command will be query, if the command
    # have the update method.
    # If the command doesn't have the update feature then that command is only used for feedback
    def SubscribeStatus(self, command, qualifier, callback):
        Command = self.Commands.get(command, None)
        if Command:
            if command not in self.Subscription:
                self.Subscription[command] = {"method": {}}

            Subscribe = self.Subscription[command]
            Method = Subscribe["method"]

            if qualifier:
                for Parameter in Command["Parameters"]:
                    try:
                        Method = Method[qualifier[Parameter]]
                    except:
                        if Parameter in qualifier:
                            Method[qualifier[Parameter]] = {}
                            Method = Method[qualifier[Parameter]]
                        else:
                            return

            Method["callback"] = callback
            Method["qualifier"] = qualifier
        else:
            raise KeyError("Invalid command for SubscribeStatus " + command)

    # This method is to check the command with new status have a callback method then trigger the callback
    def NewStatus(self, command, value, qualifier):
        if command in self.Subscription:
            Subscribe = self.Subscription[command]
            Method = Subscribe["method"]
            Command = self.Commands[command]
            if qualifier:
                for Parameter in Command["Parameters"]:
                    try:
                        Method = Method[qualifier[Parameter]]
                    except:
                        break
            if "callback" in Method and Method["callback"]:
                Method["callback"](command, value, qualifier)

    # Save new status to the command
    def WriteStatus(self, command, value, qualifier=None):
        self.counter = 0
        if not self.connectionFlag:
            self.OnConnected()
        Command = self.Commands[command]
        Status = Command["Status"]
        if qualifier:
            for Parameter in Command["Parameters"]:
                try:
                    Status = Status[qualifier[Parameter]]
                except KeyError:
                    if Parameter in qualifier:
                        Status[qualifier[Parameter]] = {}
                        Status = Status[qualifier[Parameter]]
                    else:
                        return
        try:
            if Status["Live"] != value:
                Status["Live"] = value
                self.NewStatus(command, value, qualifier)
        except:
            Status["Live"] = value
            self.NewStatus(command, value, qualifier)

    # Read the value from a command.
    def ReadStatus(self, command, qualifier=None):
        Command = self.Commands.get(command, None)
        if Command:
            Status = Command["Status"]
            if qualifier:
                for Parameter in Command["Parameters"]:
                    try:
                        Status = Status[qualifier[Parameter]]
                    except KeyError:
                        return None
            try:
                return Status["Live"]
            except:
                return None
        else:
            raise KeyError("Invalid command for ReadStatus: " + command)

    def __ReceiveData(self, interface, data):
        print("Shure MXWAPXD2 Rx Data: {}".format(data))
        # Handle incoming data
        self.__receiveBuffer += data
        index = 0  # Start of possible good data

        # check incoming data if it matched any expected data from device module
        for regexString, CurrentMatch in self.__matchStringDict.items():
            while True:
                result = re.search(regexString, self.__receiveBuffer)
                if result:
                    index = result.start()
                    CurrentMatch["callback"](result, CurrentMatch["para"])
                    self.__receiveBuffer = (
                        self.__receiveBuffer[: result.start()]
                        + self.__receiveBuffer[result.end() :]
                    )
                else:
                    break

        if index:
            # Clear out any junk data that came in before any good matches.
            self.__receiveBuffer = self.__receiveBuffer[index:]
        else:
            # In rare cases, the buffer could be filled with garbage quickly.
            # Make sure the buffer is capped.  Max buffer size set in init.
            self.__receiveBuffer = self.__receiveBuffer[-self.__maxBufferSize :]

    # Add regular expression so that it can be check on incoming data from device.
    def AddMatchString(self, regex_string, callback, arg):
        if regex_string not in self.__matchStringDict:
            self.__matchStringDict[regex_string] = {"callback": callback, "para": arg}


class EthernetClass(EthernetClientInterface, DeviceClass):

    def __init__(self, Hostname, IPPort, Protocol="TCP", ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = "Ethernet"
        DeviceClass.__init__(self)
        # Check if Model belongs to a subclass
        if len(self.Models) > 0:
            if Model not in self.Models:
                print("Model mismatch")
            else:
                self.Models[Model]()

    def Error(self, message):
        portInfo = "IP Address/Host: {0}:{1}".format(self.Hostname, self.IPPort)
        print(
            "Module: {}".format(__name__),
            portInfo,
            "Error Message: {}".format(message[0]),
            sep="\r\n",
        )

    def Discard(self, message):
        self.Error([message])

    def Disconnect(self):
        EthernetClientInterface.Disconnect(self)
        self.OnDisconnected()
