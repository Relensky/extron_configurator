from struct import pack, unpack

from extronlib.interface import EthernetClientInterface, SerialInterface

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "camera",
    "models": ["Cam570"],
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
        "btn_name": "Btn_Con_Cam2",
        "lbl_name": "Lbl_StdCam_Model",
        "gve_id": "Cam2",
        "name": "Camera - CAM570",
        "device_id": None,
        "keep_alive_command": "Power",
        "keep_alive_interval": 15,
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
        "protocol": "TCP",
        "net_port": 52381,
        "service_port": 0,
    },
    "serialoverethernet": {
        "protocol": "TCP",
        "net_port": 2001,
        "service_port": 0,
        "ip_address": "192.168.254.254",  # the Extron gateway, not the device
        "host": "processor1",
    },
    "serial": {
        "baud": 38400,
        "host": "processor1",  # the processor the COM port is on
    },
}


class DeviceClass:
    def __init__(self):
        self.WarmUpTime = 2
        self.CoolDownTime = 1
        self.Unidirectional = "False"
        self.connectionCounter = 15
        self.DefaultResponseTimeout = 0.3
        self.Subscription = {}
        self.counter = 0
        self.connectionFlag = True
        self.initializationChk = True
        self.Debug = False
        self._DeviceID = 0x81
        self.Models = {}

        self.Commands = {
            "ConnectionStatus": {"Status": {}},
            "AutoExposure": {
                "Status": {},
                "AllowedValues": [
                    "Full Auto",
                    "Manual",
                    "Shutter Priority",
                    "Iris Priority",
                    "Bright",
                ],
            },
            "BackLight": {"Status": {}, "AllowedValues": ["On", "Off"]},
            "Focus": {"Status": {}, "AllowedValues": ["Stop", "Far", "Near"]},
            "AutoFocus": {"Status": {}, "AllowedValues": ["Off", "On"]},
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
                "ParameterValues": {
                    "Pan Speed": [
                        "0",
                        "1",
                        "2",
                        "3",
                        "4",
                        "5",
                        "6",
                        "7",
                        "8",
                        "9",
                        "10",
                        "11",
                        "12",
                        "13",
                        "14",
                        "15",
                    ],
                    "Tilt Speed": [
                        "0",
                        "1",
                        "2",
                        "3",
                        "4",
                        "5",
                        "6",
                        "7",
                        "8",
                        "9",
                        "10",
                        "11",
                        "12",
                        "13",
                        "14",
                        "15",
                    ],
                },
            },
            "PIPHDMI": {
                "Status": {},
                "AllowedValues": [
                    "PTZ Lens",
                    "AI Lens",
                    "PTZ + Right Down AI",
                    "PTZ + Left Up AI",
                    "Left PTZ + Right AI",
                    "AI + Right Down PTZ",
                    "AI + Left Up PTZ",
                    "Left AI + Right PTZ",
                ],
            },
            "PIPUSB": {
                "Status": {},
                "AllowedValues": [
                    "PTZ Lens",
                    "AI Lens",
                    "PTZ + Right Down AI",
                    "PTZ + Left Up AI",
                    "Left PTZ + Right AI",
                    "AI + Right Down PTZ",
                    "AI + Left Up PTZ",
                    "Left AI + Right PTZ",
                ],
            },
            "Power": {"Status": {}, "AllowedValues": ["On", "Off", "Reboot"]},
            "Preset": {"Parameters": ["Action"], "Status": {}},
            "PresetRecall": {"Status": {}},
            "PresetSave": {"Status": {}},
            "TrackingMode": {
                "Status": {},
                "AllowedValues": [
                    "Trigger",
                    "Off",
                    "Auto Frame",
                    "Manual Frame",
                    "Audio Tracking",
                    "Audio Frame",
                    "Audio Preset",
                    "Presentation Mode",
                    "Preset Frame",
                ],
            },
            "Zoom": {"Status": {}, "AllowedValues": ["Stop", "Tele", "Wide"]},
        }

        self.start_sequence = False
        self.previous_sequence = 0
        self.last_sequence_reset = 0

    @property
    def DeviceID(self):
        return self._DeviceID

    @DeviceID.setter
    def DeviceID(self, value):
        if self.ConnectionType == "Serial":
            if 1 <= int(value) <= 7:
                self._DeviceID = 0x80 + int(value)
            else:
                print("Invalid Device ID Parameter.")
        else:
            self._DeviceID = 0x81

    def ResetSequence(self, value, qualifier):
        # Standard VISCA Reset Sequence Command
        self.Send(b"\x02\x00\x00\x01\x00\x00\x00\x00\x01")
        self.start_sequence = False
        self.previous_sequence = 0

    def next_sequence(self):
        if not self.start_sequence:
            self.start_sequence = True
            self.previous_sequence = 1
        else:
            self.previous_sequence = (self.previous_sequence + 1) & 0xFFFFFFFF

        return pack(">I", self.previous_sequence)

    def set_header(self, commandstring):
        if self.ConnectionType == "Serial":
            return commandstring
        else:
            # Payload type 0x0100 (Command)
            return (
                b"\x01\x00\x00"
                + pack("B", len(commandstring))
                + self.next_sequence()
                + commandstring
            )

    def get_header(self, commandstring):
        if self.ConnectionType == "Serial":
            return commandstring

        return (
            b"\x01\x00\x00"
            + pack("B", len(commandstring))
            + self.next_sequence()
            + commandstring
        )

    # --- Auto Exposure Methods ---
    def SetAutoExposure(self, value, qualifier):
        ValueStateValues = {
            "Full Auto": 0x00,
            "Manual": 0x03,
            "Shutter Priority": 0x0A,
            "Iris Priority": 0x0B,
            "Bright": 0x0D,
        }
        if value in ValueStateValues:
            CmdString = self.set_header(
                pack(
                    ">6B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x39,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("AutoExposure", CmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetAutoExposure")

    def UpdateAutoExposure(self, value, qualifier):
        # 81 09 04 39 FF
        CmdString = self.get_header(pack(">5B", self._DeviceID, 0x09, 0x04, 0x39, 0xFF))
        res = self.__UpdateHelper("AutoExposure", CmdString, value, qualifier)
        if res:
            try:
                ValueStateValues = {
                    0x00: "Full Auto",
                    0x03: "Manual",
                    0x0A: "Shutter Priority",
                    0x0B: "Iris Priority",
                    0x0D: "Bright",
                }
                value = ValueStateValues[res[2]]
                self.WriteStatus("AutoExposure", value, qualifier)
            except (KeyError, IndexError):
                self.Error(["AutoExposure: Invalid/unexpected response"])

    # --- BackLight Methods ---
    def SetBackLight(self, value, qualifier):
        ValueStateValues = {"On": 0x02, "Off": 0x03}
        if value in ValueStateValues:
            CmdString = self.set_header(
                pack(
                    ">6B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x33,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("BackLight", CmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetBackLight")

    def UpdateBackLight(self, value, qualifier):
        # 81 09 04 33 FF
        CmdString = self.get_header(pack(">5B", self._DeviceID, 0x09, 0x04, 0x33, 0xFF))
        res = self.__UpdateHelper("BackLight", CmdString, value, qualifier)
        if res:
            try:
                ValueStateValues = {0x02: "On", 0x03: "Off"}
                value = ValueStateValues[res[2]]
                self.WriteStatus("BackLight", value, qualifier)
            except (KeyError, IndexError):
                self.Error(["BackLight: Invalid/unexpected response"])

    def SetFocus(self, value, qualifier):
        ValueStateValues = {"Stop": 0x00, "Far": 0x30, "Near": 0x20}
        if value in ValueStateValues:
            FocusCmdString = self.set_header(
                pack(
                    ">6B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x08,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("Focus", FocusCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetFocus")

    def SetAutoFocus(self, value, qualifier):
        ValueStateValues = {"Off": 0x03, "On": 0x02}
        if value in ValueStateValues:
            AutoFocusCmdString = self.set_header(
                pack(
                    ">6B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x38,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("AutoFocus", AutoFocusCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetAutoFocus")

    def UpdateAutoFocus(self, value, qualifier):
        # 81 09 04 38 FF
        CmdString = self.get_header(pack(">5B", self._DeviceID, 0x09, 0x04, 0x38, 0xFF))
        res = self.__UpdateHelper("AutoFocus", CmdString, value, qualifier)
        if res:
            try:
                ValueStateValues = {0x02: "On", 0x03: "Off"}
                value = ValueStateValues[res[2]]
                self.WriteStatus("AutoFocus", value, qualifier)
            except (KeyError, IndexError):
                self.Error(["AutoFocus: Invalid/unexpected response"])

    def SetPanTilt(self, value, qualifier):

        ValueStateValues = {
            "Up": 0x0301,
            "Down": 0x0302,
            "Left": 0x0103,
            "Right": 0x0203,
            "Up Left": 0x0101,
            "Up Right": 0x0201,
            "Down Left": 0x0102,
            "Down Right": 0x0202,
            "Stop": 0x0303,
        }

        if not qualifier:
            qualifier = {}
        pan_speed = int(qualifier.get("Pan Speed", 8))
        tilt_speed = int(qualifier.get("Tilt Speed", 8))

        if 0 <= pan_speed <= 15 and 0 <= tilt_speed <= 15 and value in ValueStateValues:
            if value == "Stop":
                PanTiltCmdString = self.set_header(
                    pack(
                        ">6BHB",
                        self._DeviceID,
                        0x01,
                        0x06,
                        0x01,
                        0x08,
                        0x08,
                        ValueStateValues[value],
                        0xFF,
                    )
                )
            else:
                PanTiltCmdString = self.set_header(
                    pack(
                        ">6BHB",
                        self._DeviceID,
                        0x01,
                        0x06,
                        0x01,
                        pan_speed,
                        tilt_speed,
                        ValueStateValues[value],
                        0xFF,
                    )
                )
            self.__SetHelper("PanTilt", PanTiltCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPanTilt")

    def SetPIPHDMI(self, value, qualifier):

        ValueStateValues = {
            "PTZ Lens": 0x00,
            "AI Lens": 0x01,
            "PTZ + Right Down AI": 0x02,
            "PTZ + Left Up AI": 0x03,
            "Left PTZ + Right AI": 0x04,
            "AI + Right Down PTZ": 0x12,
            "AI + Left Up PTZ": 0x13,
            "Left AI + Right PTZ": 0x14,
        }

        if value in ValueStateValues:
            PIPHDMICmdString = self.set_header(
                pack(
                    ">7B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x7F,
                    0x01,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("PIPHDMI", PIPHDMICmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPIPHDMI")

    def SetPIPUSB(self, value, qualifier):

        ValueStateValues = {
            "PTZ Lens": 0x00,
            "AI Lens": 0x01,
            "PTZ + Right Down AI": 0x02,
            "PTZ + Left Up AI": 0x03,
            "Left PTZ + Right AI": 0x04,
            "AI + Right Down PTZ": 0x12,
            "AI + Left Up PTZ": 0x13,
            "Left AI + Right PTZ": 0x14,
        }

        if value in ValueStateValues:
            PIPUSBCmdString = self.set_header(
                pack(
                    ">7B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x7F,
                    0x00,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("PIPUSB", PIPUSBCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPIPUSB")

    def SetPower(self, value, qualifier):

        ValueStateValues = {"On": 0x02, "Off": 0x03, "Reboot": 0x00}

        if value in ValueStateValues:
            PowerCmdString = self.set_header(
                pack(
                    "6B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x00,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("Power", PowerCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPower")

    def UpdatePower(self, value, qualifier):
        PowerCmdString = self.get_header(
            pack(">5B", self._DeviceID, 0x09, 0x04, 0x00, 0xFF)
        )

        res = self.__UpdateHelper("Power", PowerCmdString, value, qualifier)

        if res:
            try:
                ValueStateValues = {0x02: "On", 0x03: "Off"}
                value = ValueStateValues[res[2]]
                self.WriteStatus("Power", value, qualifier)
            except (KeyError, IndexError):
                self.Error(["Power: Invalid/unexpected response"])

    def SetPresetRecall(self, value, qualifier):
        if 0 <= int(value) <= 255:
            CmdString = self.set_header(
                pack(">7B", self._DeviceID, 0x01, 0x04, 0x3F, 0x02, int(value), 0xFF)
            )
            self.__SetHelper("PresetRecall", CmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPresetRecall")

    def SetPresetSave(self, value, qualifier):
        if 0 <= int(value) <= 255:
            CmdString = self.set_header(
                pack(">7B", self._DeviceID, 0x01, 0x04, 0x3F, 0x01, int(value), 0xFF)
            )
            self.__SetHelper("PresetSave", CmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPresetSave")

    def SetPreset(self, value, qualifier):
        ActionStates = {"Save": 0x01, "Recall": 0x02}
        if (
            qualifier
            and qualifier.get("Action") in ActionStates
            and 0 <= int(value) <= 127
        ):
            PresetCmdString = self.set_header(
                pack(
                    ">7B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x3F,
                    ActionStates[qualifier["Action"]],
                    int(value),
                    0xFF,
                )
            )
            self.__SetHelper("Preset", PresetCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetPreset")

    def SetTrackingMode(self, value, qualifier):

        ValueStateValues = {
            "Trigger": 0x00,
            "Off": 0x01,
            "Auto Frame": 0x02,
            "Manual Frame": 0x03,
            "Audio Tracking": 0x04,
            "Audio Frame": 0x05,
            "Audio Preset": 0x06,
            "Presentation Mode": 0x07,
            "Preset Frame": 0x08,
        }

        if value in ValueStateValues:
            TrackingModeCmdString = self.set_header(
                pack(
                    ">7B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x7D,
                    ValueStateValues[value],
                    0x00,
                    0xFF,
                )
            )
            self.__SetHelper("TrackingMode", TrackingModeCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetTrackingMode")

    def UpdateTrackingMode(self, value, qualifier):

        TrackingModeCmdString = self.get_header(
            pack(">5B", self._DeviceID, 0x09, 0x04, 0x7D, 0xFF)
        )
        res = self.__UpdateHelper(
            "TrackingMode", TrackingModeCmdString, value, qualifier
        )
        if res:
            try:
                ValueStateValues = {
                    0x01: "Off",
                    0x02: "Auto Frame",
                    0x03: "Manual Frame",
                    0x04: "Audio Tracking",
                    0x05: "Audio Frame",
                    0x06: "Audio Preset",
                    0x07: "Presentation Mode",
                    0x08: "Preset Frame",
                }

                value = ValueStateValues[res[4]]
                self.WriteStatus("TrackingMode", value, qualifier)
            except (KeyError, IndexError, AttributeError):
                self.Error(["Tracking Mode: Invalid/unexpected response"])

    def SetZoom(self, value, qualifier):

        ValueStateValues = {"Stop": 0x00, "Tele": 0x20, "Wide": 0x30}

        if value in ValueStateValues:
            ZoomCmdString = self.set_header(
                pack(
                    ">6B",
                    self._DeviceID,
                    0x01,
                    0x04,
                    0x07,
                    ValueStateValues[value],
                    0xFF,
                )
            )
            self.__SetHelper("Zoom", ZoomCmdString, value, qualifier)
        else:
            self.Discard("Invalid Command for SetZoom")

    def __CheckResponseForErrors(self, sourceCmdName, response):
        if self.ConnectionType != "Serial":
            # Remove header (8 bytes: 01 00 00 Length Sequence Sequence Payload...)
            if len(response) > 8:
                response = response[8:]

        if response and len(response) >= 4:
            try:
                address, errorbyte, errorcode, terminator = unpack(">4B", response[:4])
            except Exception as e:
                self.Error(["Response unpacking error: {}".format(e)])
                return b""
            if errorbyte & 0x60 == 0x60:  # Error reported by camera
                self.Error(["An error occurred: {}".format(response)])
                return b""
            return response
        elif response and len(response) == 2:
            # Keep-alive packet (b'\x90\xff' or similar)
            if response[0] == 0x90 and response[1] == 0xFF:
                return b""  # Valid keep-alive, but no data to process

        return b""

    def __SetHelper(self, command, commandstring, value, qualifier):
        self.Debug = True
        # PTZ/startup Set commands run from UI events, so do not block on ACKs.
        self.Send(commandstring)

    def __UpdateHelper(self, command, commandstring, value, qualifier):
        if self.Unidirectional == "True":
            self.Discard("Inappropriate Command " + command)
            return ""
        else:
            if self.initializationChk:
                self.OnConnected()
                self.initializationChk = False

            self.counter = self.counter + 1
            if self.counter > self.connectionCounter and self.connectionFlag:
                self.OnDisconnected()

            res = self.SendAndWait(
                commandstring, self.DefaultResponseTimeout, deliTag=b"\xff"
            )
            if not res:
                # TIMEOUT: Reset Sequence on update failure too
                self.ResetSequence(None, None)
                return ""
            else:
                return self.__CheckResponseForErrors(command, res)

    def OnConnected(self):
        self.connectionFlag = True
        self.WriteStatus("ConnectionStatus", "Connected")
        self.counter = 0
        # Reset sequence on new connection
        self.ResetSequence(None, None)

    def OnDisconnected(self):
        self.WriteStatus("ConnectionStatus", "Disconnected")
        self.connectionFlag = False
        self.start_sequence = False
        self.previous_sequence = 0

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


class SerialClass(SerialInterface, DeviceClass):
    def __init__(
        self,
        Host,
        Port,
        Baud=38400,
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
        DeviceClass.__init__(self)
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


class SerialOverEthernetClass(EthernetClientInterface, DeviceClass):
    def __init__(self, Hostname, IPPort, Protocol="TCP", ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = "Serial"
        DeviceClass.__init__(self)
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


class EthernetClass(EthernetClientInterface, DeviceClass):
    def __init__(self, Hostname, IPPort, Protocol="TCP", ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = "Ethernet"
        DeviceClass.__init__(self)
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
