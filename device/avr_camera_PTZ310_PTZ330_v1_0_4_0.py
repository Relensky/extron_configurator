import re
from struct import pack

from extronlib.interface import EthernetClientInterface, SerialInterface
from extronlib.system import ProgramLog, Wait

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "camera",
    "models": ["PTZ310", "PTZ330", "PTZ310W", "PTZ330W"],
    "connection": {
        "com_type": "Network",
        "protocol": "UDP",
        "net_port": 52381,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",  # site-specific — blank
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_Cam1",
        "lbl_name": "Lbl_InstCam_Model",
        "gve_id": "Cam1",
        "name": "Camera - PTZ310",
        "device_id": None,
        "keep_alive_command": "Power",
        "keep_alive_interval": 10,
        "keep_alive_trigger": None,
        "manual_disconnect": False,
        "user": "averadmin",
        "password": "ATEC2008",
    },
    # How this driver is reached on each connection style, read by the app:
    # changing com_type loads the matching block, and picking a model merges it
    # over "connection" + "defaults". Ports are the ones the module's
    # communication sheet documents; protocol, baud and service port are the
    # defaults declared by the wrapper classes at the bottom of this file.
    "network": {
        "protocol": "UDP",
        "net_port": 52381,
        "service_port": 0,
    },
    "serialoverethernet": {
        "protocol": "TCP",
        "net_port": 2001,
        "service_port": 0,
        "ip_address": "192.168.254.254",  # the Extron gateway, not the device
        "password": "ATEC2007",  # the gateway, like the address above
        "host": "processor1",
    },
    "serial": {
        "baud": 9600,
        "host": "processor1",  # the processor the COM port is on
    },
}


class DeviceSerialClass:
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
        self._DeviceID = b"\x81"
        self.Models = {}

        self.Commands = {
            "ConnectionStatus": {"Status": {}},
            "AutoExposure": {
                "Status": {},
                "AllowedValues": [
                    "Full Auto",
                    "Iris Priority",
                    "Shutter Priority",
                    "Manual",
                ],
            },
            "BackLight": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "ExposureValue": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "Focus": {"Status": {}, "AllowedValues": ["Far", "Near", "Stop"]},
            "AutoFocus": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "GainLevel": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "Home": {"Status": {}},
            "Iris": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "PanTilt": {
                "Parameters": ["Pan Speed", "Tilt Speed"],
                "Status": {},
                "AllowedValues": [
                    "Up",
                    "Down",
                    "Left",
                    "Right",
                    "Up Left",
                    "Up Right",
                    "Down Left",
                    "Down Right",
                    "Stop",
                ],
            },
            "Power": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "PresetRecall": {"Status": {}},
            "PresetSave": {"Status": {}},
            "ShutterSpeed": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "SmartShoot": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "SystemMenu": {"Status": {}, "AllowedValues": ["On", "Off", "Enter"]},
            "WhiteBalance": {
                "Status": {},
                "AllowedValues": ["Auto", "Indoor", "Outdoor", "One Push", "Manual"],
            },
            "Zoom": {
                "Parameters": ["Zoom Speed"],
                "Status": {},
                "AllowedValues": ["Tele", "Wide", "Stop"],
            },
        }

        if self.Unidirectional == "False":
            self.AddMatchString(
                re.compile(b"[\x90\xa0\xb0\xc0\xd0\xe0\xf0]\x50([\x02\x03])\xff"),
                self.__MatchPower,
                None,
            )
            self.AddMatchString(
                re.compile(b"[\x90\xa0\xb0\xc0\xd0\xe0\xf0](\x60\x02|\x61\x41)\xff"),
                self.__MatchError,
                None,
            )

    @property
    def DeviceID(self):
        return self._DeviceID

    @DeviceID.setter
    def DeviceID(self, value):
        if 1 <= int(value) <= 7:
            self._DeviceID = bytes([0x80 + int(value)])
        else:
            print("Invalid Device ID Parameter.")

    def SetAutoExposure(self, value, qualifier):

        ValueStateValues = {
            "Full Auto": b"\x00",
            "Iris Priority": b"\x0b",
            "Shutter Priority": b"\x0a",
            "Manual": b"\x03",
        }

        if value in ValueStateValues:
            AutoExposureCmdString = (
                self._DeviceID + b"\x01\x04\x39" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("AutoExposure", AutoExposureCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetAutoExposure")

    def SetBackLight(self, value, qualifier):

        ValueStateValues = {"On": b"\x02", "Off": b"\x03"}

        if value in ValueStateValues:
            BackLightCmdString = (
                self._DeviceID + b"\x01\x04\x33" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("BackLight", BackLightCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetBackLight")

    def SetExposureValue(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            ExposureValueCmdString = (
                self._DeviceID + b"\x01\x04\x0e" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("ExposureValue", ExposureValueCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetExposureValue")

    def SetFocus(self, value, qualifier):

        ValueStateValues = {
            "Far": b"\x02",
            "Near": b"\x03",
            "Stop": b"\x00",
        }

        if value in ValueStateValues:
            FocusCmdString = (
                self._DeviceID + b"\x01\x04\x08" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("Focus", FocusCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetFocus")

    def SetAutoFocus(self, value, qualifier):

        ValueStateValues = {"On": b"\x02", "Off": b"\x03"}

        if value in ValueStateValues:
            AutoFocusCmdString = (
                self._DeviceID + b"\x01\x04\x38" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("AutoFocus", AutoFocusCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetAutoFocus")

    def SetGainLevel(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            GainLevelCmdString = (
                self._DeviceID + b"\x01\x04\x0c" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("GainLevel", GainLevelCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetGainLevel")

    def SetHome(self, value, qualifier):

        HomeCmdString = self._DeviceID + b"\x01\x06\x04\xff"
        self.__SetHelper("Home", HomeCmdString, value, qualifier)

    def SetIris(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            IrisCmdString = (
                self._DeviceID + b"\x01\x04\x0b" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("Iris", IrisCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetIris")

    def SetPanTilt(self, value, qualifier):
        ValueStateValues = {
            "Up": b"\x03\x01",
            "Down": b"\x03\x02",
            "Left": b"\x01\x03",
            "Right": b"\x02\x03",
            "Up Left": b"\x01\x01",
            "Up Right": b"\x02\x01",
            "Down Left": b"\x01\x02",
            "Down Right": b"\x02\x02",
            "Stop": b"\x03\x03",
        }

        if (
            1 <= int(qualifier["Pan Speed"]) <= 24
            and 1 <= int(qualifier["Tilt Speed"]) <= 24
            and value in ValueStateValues
        ):
            PanTiltCmdString = (
                self._DeviceID
                + b"\x01\x06\x01"
                + bytes([int(qualifier["Pan Speed"]), int(qualifier["Tilt Speed"])])
                + ValueStateValues[value]
                + b"\xff"
            )
            print("PTZ310W PTZ CMD: {}".format(PanTiltCmdString))
            self.__SetHelper("PanTilt", PanTiltCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPanTilt")

    def SetPower(self, value, qualifier):

        ValueStateValues = {"On": b"\x02", "Off": b"\x03"}

        if value in ValueStateValues:
            PowerCmdString = (
                self._DeviceID + b"\x01\x04\x00" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("Power", PowerCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPower")

    def UpdatePower(self, value, qualifier):

        PowerCmdString = self._DeviceID + b"\x09\x04\x00\xff"
        print("PTZ310W Power CMD: {}".format(PowerCmdString))
        self.__UpdateHelper("Power", PowerCmdString, value, qualifier)

    def __MatchPower(self, match, tag):

        ValueStateValues = {b"\x02": "On", b"\x03": "Off"}

        value = ValueStateValues[match.group(1)]
        self.WriteStatus("Power", value, None)

    def SetPresetRecall(self, value, qualifier):

        if 0 <= int(value) <= 255:
            PresetRecallCmdString = (
                self._DeviceID + b"\x01\x04\x3f\x02" + bytes([int(value)]) + b"\xff"
            )
            self.__SetHelper("PresetRecall", PresetRecallCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPresetRecall")

    def SetPresetSave(self, value, qualifier):

        if 0 <= int(value) <= 255:
            PresetSaveCmdString = (
                self._DeviceID + b"\x01\x04\x3f\x01" + bytes([int(value)]) + b"\xff"
            )
            self.__SetHelper("PresetSave", PresetSaveCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPresetSave")

    def SetShutterSpeed(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            ShutterSpeedCmdString = (
                self._DeviceID + b"\x01\x04\x0a" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("ShutterSpeed", ShutterSpeedCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetShutterSpeed")

    def SetSmartShoot(self, value, qualifier):

        ValueStateValues = {"On": b"\x5d", "Off": b"\x5e"}

        if value in ValueStateValues:
            SmartShootCmdString = (
                self._DeviceID + b"\x01\x04\x3f\x01" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("SmartShoot", SmartShootCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetSmartShoot")

    def SetSystemMenu(self, value, qualifier):

        ValueStateValues = {
            "On": b"\x01\x06\x06\x02\xff",
            "Off": b"\x01\x06\x06\x03\xff",
            "Enter": b"\x01\x7e\x01\x02\x00\x01\xff",
        }

        if value in ValueStateValues:
            SystemMenuCmdString = self._DeviceID + ValueStateValues[value]
            self.__SetHelper("SystemMenu", SystemMenuCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetSystemMenu")

    def SetWhiteBalance(self, value, qualifier):

        ValueStateValues = {
            "Auto": b"\x00",
            "Indoor": b"\x01",
            "Outdoor": b"\x02",
            "One Push": b"\x03",
            "Manual": b"\x05",
        }

        if value in ValueStateValues:
            WhiteBalanceCmdString = (
                self._DeviceID + b"\x01\x04\x35" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("WhiteBalance", WhiteBalanceCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetWhiteBalance")

    def SetZoom(self, value, qualifier):

        if 0 <= int(qualifier["Zoom Speed"]) <= 7 and value in ["Tele", "Wide", "Stop"]:
            ValueStateValues = {
                "Tele": 0x20 + int(qualifier["Zoom Speed"]),
                "Wide": 0x30 + int(qualifier["Zoom Speed"]),
                "Stop": 0x00,
            }

            ZoomCmdString = (
                self._DeviceID
                + b"\x01\x04\x07"
                + bytes([ValueStateValues[value]])
                + b"\xff"
            )
            print("PTZ310W Zoom CMD: {}".format(ZoomCmdString))
            self.__SetHelper("Zoom", ZoomCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetZoom")

    def __SetHelper(self, command, commandstring, value, qualifier):
        print("PTZ310W send CMD: {}".format(commandstring))
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

        DEVICE_ERROR_CODES = {
            b"\x60\x02": "Syntax Error.",
            b"\x61\x41": "Command Not Executable.",
        }

        self.Error([DEVICE_ERROR_CODES[match.group(1)]])

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
        print("PTZ310W Update Method: {}".format(method))
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


class DeviceEthernetClass:
    def __init__(self):

        self.Debug = False
        self._DeviceID = b"\x81"
        self.Models = {}

        # The vendor shipped this class without the status/lifecycle API that
        # DeviceSerialClass carries, so EthernetClass had no OnConnected /
        # OnDisconnected / WriteStatus / SubscribeStatus. The framework calls
        # OnDisconnected() unguarded during device init, which raised
        # AttributeError and silently discarded the whole handler. The state
        # below backs the methods added at the end of this class.
        self.Unidirectional = "False"
        self.connectionCounter = 15
        self.connectionFlag = True
        self.initializationChk = True
        self.counter = 0
        self.Subscription = {}
        self.ReceiveData = self.__ReceiveData
        self.__receiveBuffer = b""
        self.__maxBufferSize = 2048
        self.__matchStringDict = {}

        self.Commands = {
            "ConnectionStatus": {"Status": {}},
            "AutoExposure": {
                "Status": {},
                "AllowedValues": [
                    "Full Auto",
                    "Iris Priority",
                    "Shutter Priority",
                    "Manual",
                ],
            },
            "BackLight": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "ExposureValue": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "Focus": {"Status": {}, "AllowedValues": ["Far", "Near", "Stop"]},
            "AutoFocus": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "GainLevel": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "Home": {"Status": {}},
            "Iris": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "PanTilt": {
                "Parameters": ["Pan Speed", "Tilt Speed"],
                "Status": {},
                "AllowedValues": [
                    "Up",
                    "Down",
                    "Left",
                    "Right",
                    "Up Left",
                    "Up Right",
                    "Down Left",
                    "Down Right",
                    "Stop",
                ],
            },
            "Power": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "PresetRecall": {"Status": {}},
            "PresetSave": {"Status": {}},
            "ShutterSpeed": {"Status": {}, "AllowedValues": ["Reset", "Up", "Down"]},
            "SmartShoot": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "SystemMenu": {"Status": {}, "AllowedValues": ["On", "Off", "Enter"]},
            "WhiteBalance": {
                "Status": {},
                "AllowedValues": ["Auto", "Indoor", "Outdoor", "One Push", "Manual"],
            },
            "Zoom": {
                "Parameters": ["Zoom Speed"],
                "Status": {},
                "AllowedValues": ["Tele", "Wide", "Stop"],
            },
        }

        # VISCA-over-IP replies carry the same payload as serial, wrapped in the
        # 8 byte header, so the serial patterns match once re.search skips it.
        if self.Unidirectional == "False":
            self.AddMatchString(
                re.compile(b"[\x90\xa0\xb0\xc0\xd0\xe0\xf0]\x50([\x02\x03])\xff"),
                self.__MatchPower,
                None,
            )
            self.AddMatchString(
                re.compile(b"[\x90\xa0\xb0\xc0\xd0\xe0\xf0](\x60\x02|\x61\x41)\xff"),
                self.__MatchError,
                None,
            )

    @property
    def DeviceID(self):
        return self._DeviceID

    @DeviceID.setter
    def DeviceID(self, value):
        if 1 <= int(value) <= 7:
            self._DeviceID = bytes([0x80 + int(value)])
        else:
            print("Invalid Device ID Parameter.")

    def SetHeader(self, commandstring):
        return (
            b"\x01\x00\x00"
            + pack("B", len(commandstring))
            + b"\x00\x00\x00\x01"
            + commandstring
        )

    def SetAutoExposure(self, value, qualifier):

        ValueStateValues = {
            "Full Auto": b"\x00",
            "Iris Priority": b"\x0b",
            "Shutter Priority": b"\x0a",
            "Manual": b"\x03",
        }

        if value in ValueStateValues:
            AutoExposureCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x39" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("AutoExposure", AutoExposureCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetAutoExposure")

    def SetBackLight(self, value, qualifier):

        ValueStateValues = {"On": b"\x02", "Off": b"\x03"}

        if value in ValueStateValues:
            BackLightCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x33" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("BackLight", BackLightCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetBackLight")

    def SetExposureValue(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            ExposureValueCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x0e" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("ExposureValue", ExposureValueCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetExposureValue")

    def SetFocus(self, value, qualifier):

        ValueStateValues = {
            "Far": b"\x02",
            "Near": b"\x03",
            "Stop": b"\x00",
        }

        if value in ValueStateValues:
            FocusCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x08" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("Focus", FocusCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetFocus")

    def SetAutoFocus(self, value, qualifier):

        ValueStateValues = {"On": b"\x02", "Off": b"\x03"}

        if value in ValueStateValues:
            AutoFocusCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x38" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("AutoFocus", AutoFocusCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetAutoFocus")

    def SetGainLevel(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            GainLevelCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x0c" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("GainLevel", GainLevelCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetGainLevel")

    def SetHome(self, value, qualifier):

        HomeCmdString = self.SetHeader(self._DeviceID + b"\x01\x06\x04\xff")
        self.__SetHelper("Home", HomeCmdString, value, qualifier)

    def SetIris(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            IrisCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x0b" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("Iris", IrisCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetIris")

    def SetPanTilt(self, value, qualifier):

        ValueStateValues = {
            "Up": b"\x03\x01",
            "Down": b"\x03\x02",
            "Left": b"\x01\x03",
            "Right": b"\x02\x03",
            "Up Left": b"\x01\x01",
            "Up Right": b"\x02\x01",
            "Down Left": b"\x01\x02",
            "Down Right": b"\x02\x02",
            "Stop": b"\x03\x03",
        }

        if (
            1 <= qualifier["Pan Speed"] <= 24
            and 1 <= qualifier["Tilt Speed"] <= 24
            and value in ValueStateValues
        ):
            PanTiltCmdString = self.SetHeader(
                self._DeviceID
                + b"\x01\x06\x01"
                + bytes([qualifier["Pan Speed"], qualifier["Tilt Speed"]])
                + ValueStateValues[value]
                + b"\xff"
            )
            self.__SetHelper("PanTilt", PanTiltCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPanTilt")

    def SetPower(self, value, qualifier):

        ValueStateValues = {"On": b"\x02", "Off": b"\x03"}

        if value in ValueStateValues:
            PowerCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x00" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("Power", PowerCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPower")

    def SetPresetRecall(self, value, qualifier):

        if 0 <= int(value) <= 255:
            PresetRecallCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x3f\x02" + bytes([int(value)]) + b"\xff"
            )
            self.__SetHelper("PresetRecall", PresetRecallCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPresetRecall")

    def SetPresetSave(self, value, qualifier):

        if 0 <= int(value) <= 255:
            PresetSaveCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x3f\x01" + bytes([int(value)]) + b"\xff"
            )
            self.__SetHelper("PresetSave", PresetSaveCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPresetSave")

    def SetShutterSpeed(self, value, qualifier):

        ValueStateValues = {"Reset": b"\x00", "Up": b"\x02", "Down": b"\x03"}

        if value in ValueStateValues:
            ShutterSpeedCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x0a" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("ShutterSpeed", ShutterSpeedCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetShutterSpeed")

    def SetSmartShoot(self, value, qualifier):

        ValueStateValues = {"On": b"\x5d", "Off": b"\x5e"}

        if value in ValueStateValues:
            SmartShootCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x3f\x01" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("SmartShoot", SmartShootCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetSmartShoot")

    def SetSystemMenu(self, value, qualifier):

        ValueStateValues = {
            "On": b"\x01\x06\x06\x02\xff",
            "Off": b"\x01\x06\x06\x03\xff",
            "Enter": b"\x01\x7e\x01\x02\x00\x01\xff",
        }

        if value in ValueStateValues:
            SystemMenuCmdString = self.SetHeader(
                self._DeviceID + ValueStateValues[value]
            )
            self.__SetHelper("SystemMenu", SystemMenuCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetSystemMenu")

    def SetWhiteBalance(self, value, qualifier):

        ValueStateValues = {
            "Auto": b"\x00",
            "Indoor": b"\x01",
            "Outdoor": b"\x02",
            "One Push": b"\x03",
            "Manual": b"\x05",
        }

        if value in ValueStateValues:
            WhiteBalanceCmdString = self.SetHeader(
                self._DeviceID + b"\x01\x04\x35" + ValueStateValues[value] + b"\xff"
            )
            self.__SetHelper("WhiteBalance", WhiteBalanceCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetWhiteBalance")

    def SetZoom(self, value, qualifier):

        if 0 <= int(qualifier["Zoom Speed"]) <= 7 and value in ["Tele", "Wide", "Stop"]:
            ValueStateValues = {
                "Tele": 0x20 + int(qualifier["Zoom Speed"]),
                "Wide": 0x30 + int(qualifier["Zoom Speed"]),
                "Stop": 0x00,
            }

            ZoomCmdString = self.SetHeader(
                self._DeviceID
                + b"\x01\x04\x07"
                + bytes([ValueStateValues[value]])
                + b"\xff"
            )
            self.__SetHelper("Zoom", ZoomCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetZoom")

    def __SetHelper(self, command, commandstring, value, qualifier):
        print("PTZ310W send CMD: {}".format(commandstring))
        self.Debug = True

        self.Send(b"\x02\x00\x00\x01\x00\x00\x00\x00\x01")
        self.Send(commandstring)

    def UpdatePower(self, value, qualifier):

        PowerCmdString = self.SetHeader(self._DeviceID + b"\x09\x04\x00\xff")
        self.__UpdateHelper("Power", PowerCmdString, value, qualifier)

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

    def __MatchPower(self, match, tag):

        ValueStateValues = {b"\x02": "On", b"\x03": "Off"}

        value = ValueStateValues[match.group(1)]
        self.WriteStatus("Power", value, None)

    def __MatchError(self, match, tag):
        self.counter = 0

        DEVICE_ERROR_CODES = {
            b"\x60\x02": "Syntax Error.",
            b"\x61\x41": "Command Not Executable.",
        }

        self.Error([DEVICE_ERROR_CODES[match.group(1)]])

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


class SerialClass(SerialInterface, DeviceSerialClass):
    def __init__(
        self,
        Host,
        Port,
        Baud=9600,
        Data=8,
        Parity="None",
        Stop=1,
        FlowControl="Off",
        CharDelay=0,
        Mode="RS232",
        Model=None,
    ):
        SerialInterface.__init__(
            self, Host, Port, Baud, Data, Parity, Stop, FlowControl, CharDelay, Mode
        )
        self.ConnectionType = "Serial"
        DeviceSerialClass.__init__(self)
        # Check if Model belongs to a subclass
        if len(self.Models) > 0:
            if Model not in self.Models:
                print("Model mismatch")
            else:
                self.Models[Model]()

    def Error(self, message):
        portInfo = "Host Alias: {0}, Port: {1}".format(self.Host.DeviceAlias, self.Port)
        print(
            "Module: {}".format(__name__),
            portInfo,
            "Error Message: {}".format(message[0]),
            sep="\r\n",
        )

    def Discard(self, message):
        self.Error([message])


class SerialOverEthernetClass(EthernetClientInterface, DeviceSerialClass):
    def __init__(self, Hostname, IPPort, Protocol="TCP", ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = "Serial"
        DeviceSerialClass.__init__(self)
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


class EthernetClass(EthernetClientInterface, DeviceEthernetClass):
    def __init__(self, Hostname, IPPort, Protocol="UDP", ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = "Ethernet"
        DeviceEthernetClass.__init__(self)
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
