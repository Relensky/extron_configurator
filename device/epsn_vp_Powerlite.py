from extronlib.interface import SerialInterface, EthernetClientInterface
import re

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "projector",
    "models": [
        "EB-L615U",
        "EB-L610U",
        "CB-L615U",
        "CB-L610U",
        "PowerLite L615U",
        "PowerLite L610U",
        "EB-L510U",
        "EB-L610W",
        "CB-L510U",
        "CB-L610W",
        "PowerLite L510U",
        "PowerLite L610W",
        "EB-L400U",
        "EB-L500W",
        "EB-L610",
        "EB-L500",
        "CB-L400U",
        "CB-L500W",
        "CB-L610",
        "CB-L500",
        "PowerLite L400U",
        "PowerLite L500W",
        "PowerLite L610",
        "PowerLite L500",
        "EB-L735U",
        "EB-L730U",
        "EB-L720U",
        "EB-L630U",
        "EB-L635SU",
        "EB-L630SU",
        "EB-L530U",
        "EB-L520U",
        "EB-L630W",
        "CB-L735U",
        "CB-L730U",
        "CB-L720U",
        "CB-L630U",
        "CB-L635SU",
        "CB-L630SU",
        "CB-L530U",
        "CB-L520U",
        "CB-L630W",
        "PowerLite L735U",
        "PowerLite L730U",
        "PowerLite L720U",
        "PowerLite L630U",
        "PowerLite L635SU",
        "PowerLite L630SU",
        "PowerLite L530U",
        "PowerLite L520U",
        "PowerLite L630W",
        "EB-L520W",
        "CB-L520W",
        "PowerLite L520W",
        "EB-L775U",
        "EB-L770U",
        "EB-L570U",
        "CB-L775U",
        "CB-L770U",
        "CB-L570U",
        "EB-L895E",
        "EB-L890E",
        "EB-L690E",
        "EB-L795SE",
        "EB-L790SE",
        "EB-L895U",
        "EB-L890U",
        "EB-L790U",
        "EB-L690U",
        "EB-L790SU",
        "EB-L690SU",
        "EB-L695SU",
        "CB-L895E",
        "CB-L890E",
        "CB-L690E",
        "CB-L795SE",
        "CB-L790SE",
        "CB-L895U",
        "CB-L890U",
        "CB-L790U",
        "CB-L690U",
        "CB-L790SU",
        "CB-L690SU",
        "CB-L695SU",
        "EB-L695SE",
        "EB-L690SE",
        "EB-L790G",
        "EB-L590SE",
        "CB-L695SE",
        "CB-L690SE",
        "CB-L790G",
        "CB-L590SE",
        "EB-L600U",
        "EB-L690",
    ],
    # What each group of models can do, from the ESC/VP21 command list
    # (Rev.W). Read by the app, which offers a device only its model's
    # commands and inputs, AND by DeviceClass below, which narrows itself to
    # the same group - so the two can never disagree.
    "model_support": {
        # Sheet L610U: HDBaseT and Screen Mirroring
        "L615U": {
            "models": [
                "EB-L615U", "EB-L610U", "CB-L615U", "CB-L610U",
                "PowerLite L615U", "PowerLite L610U",
            ],
            "values": {
                "Input": [
                    "Computer 1", "Computer 1 (RGB)", "Computer 1 (Component)", "Computer 2",
                    "Computer 2 (RGB)", "Computer 2 (Component)", "HDMI 1", "HDMI 2",
                    "HDBaseT", "USB", "LAN", "Screen Mirroring",
                ],
            },
        },
        # Sheet L610U: HDBaseT, no Screen Mirroring (EB-L600U is not on the sheet)
        "L510U": {
            "models": [
                "EB-L510U", "EB-L610W", "CB-L510U", "CB-L610W",
                "PowerLite L510U", "PowerLite L610W", "EB-L600U",
            ],
            "values": {
                "Input": [
                    "Computer 1", "Computer 1 (RGB)", "Computer 1 (Component)", "Computer 2",
                    "Computer 2 (RGB)", "Computer 2 (Component)", "HDMI 1", "HDMI 2",
                    "HDBaseT", "USB", "LAN",
                ],
            },
        },
        # Sheet L610U: no HDBaseT
        "L400U": {
            "models": [
                "EB-L400U", "EB-L500W", "EB-L610", "EB-L500",
                "CB-L400U", "CB-L500W", "CB-L610", "CB-L500",
                "PowerLite L400U", "PowerLite L500W", "PowerLite L610", "PowerLite L500",
            ],
            "values": {
                "Input": [
                    "Computer 1", "Computer 1 (RGB)", "Computer 1 (Component)", "Computer 2",
                    "Computer 2 (RGB)", "Computer 2 (Component)", "HDMI 1", "HDMI 2",
                    "USB", "LAN",
                ],
            },
        },
        # Sheet L730U: Computer 1/2 only as 10/20 (11/14/21/24 answer ERR), no SPS 05
        "L730U": {
            "models": [
                "EB-L735U", "EB-L730U", "EB-L720U", "EB-L630U",
                "EB-L635SU", "EB-L630SU", "EB-L530U", "EB-L520U",
                "EB-L630W", "CB-L735U", "CB-L730U", "CB-L720U",
                "CB-L630U", "CB-L635SU", "CB-L630SU", "CB-L530U",
                "CB-L520U", "CB-L630W", "PowerLite L735U", "PowerLite L730U",
                "PowerLite L720U", "PowerLite L630U", "PowerLite L635SU", "PowerLite L630SU",
                "PowerLite L530U", "PowerLite L520U", "PowerLite L630W",
            ],
            "unsupported": ["SplitScreenSwap"],
            "values": {
                "Input": [
                    "Computer 1", "Computer 2", "HDMI 1", "HDMI 2",
                    "HDBaseT", "USB", "LAN", "Screen Mirroring",
                ],
            },
        },
        # Sheet L730U, L520W column: no Screen Mirroring, has SPS 05
        "L520W": {
            "models": [
                "EB-L520W", "CB-L520W", "PowerLite L520W",
            ],
            "values": {
                "Input": [
                    "Computer 1", "Computer 2", "HDMI 1", "HDMI 2",
                    "HDBaseT", "USB", "LAN",
                ],
            },
        },
        # Sheet L570U: no computer inputs, no KEY 4A
        "L570U": {
            "models": [
                "EB-L775U", "EB-L770U", "EB-L570U", "CB-L775U",
                "CB-L770U", "CB-L570U",
            ],
            "unsupported": ["AutoImage"],
            "values": {
                "Input": [
                    "HDMI 1", "HDMI 2", "HDBaseT", "USB",
                    "LAN",
                ],
            },
        },
        # Sheet L890E: Miracast (56) and AirPlay (E0, not on ECC models), no KEY 4A or SPS 05
        "L890E": {
            "models": [
                "EB-L895E", "EB-L890E", "EB-L690E", "EB-L795SE",
                "EB-L790SE", "EB-L895U", "EB-L890U", "EB-L790U",
                "EB-L690U", "EB-L790SU", "EB-L690SU", "EB-L695SU",
                "CB-L895E", "CB-L890E", "CB-L690E", "CB-L795SE",
                "CB-L790SE", "CB-L895U", "CB-L890U", "CB-L790U",
                "CB-L690U", "CB-L790SU", "CB-L690SU", "CB-L695SU",
                "PowerLite L895E", "PowerLite L890E", "PowerLite L690E", "PowerLite L795SE",
                "PowerLite L790SE", "PowerLite L895U", "PowerLite L890U", "PowerLite L790U",
                "PowerLite L690U", "PowerLite L790SU", "PowerLite L690SU", "PowerLite L695SU",
            ],
            "unsupported": ["AutoImage", "SplitScreenSwap"],
            "values": {
                "Input": [
                    "HDMI 1", "HDMI 2", "HDBaseT", "USB",
                    "LAN", "Screen Mirroring", "AirPlay",
                ],
            },
        },
        # Sheet L890E: L690SE/L695SE/L790G/L590SE have no Miracast/AirPlay
        "L890SE": {
            "models": [
                "EB-L695SE", "EB-L690SE", "EB-L790G", "EB-L590SE",
                "CB-L695SE", "CB-L690SE", "CB-L790G", "CB-L590SE",
                "PowerLite L695SE", "PowerLite L690SE", "PowerLite L790G", "PowerLite L590SE",
                "EB-L690",
            ],
            "unsupported": ["AutoImage", "SplitScreenSwap"],
            "values": {
                "Input": [
                    "HDMI 1", "HDMI 2", "HDBaseT", "USB",
                    "LAN",
                ],
            },
        },
    },
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 3629,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",
    },
    "defaults": {
        "btn_name": "Btn_Con_Projector1",
        "lbl_name": "Lbl_Proj_Model_Proj1",
        "gve_id": "Proj1",
        "name": "Projector - EB-L610W",
        "device_id": None,
        "keep_alive_command": "Power",
        "keep_alive_interval": 10,
        "keep_alive_trigger": None,
        "manual_disconnect": False,
        "user": "",
        "password": "ATEC2008",
    },
    # How this driver is reached on each connection style, read by the app:
    # changing com_type loads the matching block, and picking a model merges
    # it over "connection" + "defaults".
    "serial": {
        "host": "processor1",
        "baud": 9600,
    },
    "serialoverethernet": {
        "protocol": "TCP",
        "net_port": 2001,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "192.168.254.254",
        "password": "ATEC2007",
    },
    "network": {
        "protocol": "TCP",
        "net_port": 3629,
        "service_port": 0,
    },
}


class DeviceClass:

    # SOURCE codes from the ESC/VP21 command list (Rev.W). Each model method
    # at the bottom picks the ones its projector accepts.
    InputCodes = {
        'Computer 1' : '10',
        'Computer 1 (RGB)' : '11',
        'Computer 1 (Component)' : '14',
        'Computer 2' : '20',
        'Computer 2 (RGB)' : '21',
        'Computer 2 (Component)' : '24',
        'HDMI 1' : '30',
        'USB' : '52',
        'LAN' : '53',
        'Screen Mirroring' : '56',
        'HDBaseT' : '80',
        'HDMI 2' : 'A0',
        'AirPlay' : 'E0',
    }

    # Every code SOURCE? can answer with, for any model ('1F'/'2F' are the
    # Auto sub-modes of Computer 1/2, '59' the second mirroring source).
    InputStatusNames = {
        '10' : 'Computer 1',
        '11' : 'Computer 1 (RGB)',
        '14' : 'Computer 1 (Component)',
        '1F' : 'Computer 1',
        '20' : 'Computer 2',
        '21' : 'Computer 2 (RGB)',
        '24' : 'Computer 2 (Component)',
        '2F' : 'Computer 2',
        '30' : 'HDMI 1',
        '52' : 'USB',
        '53' : 'LAN',
        '56' : 'Screen Mirroring',
        '59' : 'Screen Mirroring',
        '80' : 'HDBaseT',
        'A0' : 'HDMI 2',
        'E0' : 'AirPlay',
    }

    DefaultInputs = ['Computer 1 (RGB)', 'Computer 1 (Component)', 'Computer 2 (RGB)', 'Computer 2 (Component)', 'HDMI 1', 'USB', 'LAN', 'HDMI 2', 'HDBaseT']

    def __init__(self):

        self.WarmUpTime = 45.0
        self.CoolDownTime = 15.0
        self.Unidirectional = 'False'
        self.connectionCounter = 15
        self.DefaultResponseTimeout = 0.3
        self._compile_list = {}
        self.Subscription = {}
        self.ReceiveData = self.__ReceiveData
        self._ReceiveBuffer = b''
        self.counter = 0
        self.connectionFlag = True
        self.initializationChk = True
        self.Debug = False
        # Per-model capabilities, narrowed by the model methods at the bottom
        # (ESC/VP21 command list Rev.W). The defaults are used for a model name
        # that is not in self.Models.
        self.Unsupported = set()
        self.SetInputStateValues = {name: self.InputCodes[name] for name in self.DefaultInputs}
        self.UpdateInputStateValues = self.InputStatusNames
        # Every model in DEVICE_INFO["model_support"], each narrowing the driver
        # to its own group's commands and inputs when the wrapper calls it.
        self.Models = {}
        for group in DEVICE_INFO['model_support'].values():
            for model in group['models']:
                self.Models[model] = (lambda group=group: self.__UseModelSupport(group))

        self.Commands = {
            'ConnectionStatus': {'Status': {}},
            'AspectRatio': { 'Status': {}, 'AllowedValues': ['Normal', '16:9', 'Auto', 'Full', 'H-Zoom', 'Native', 'V-Zoom', '4:3']},
            'AutoImage': { 'Status': {}},
            'AVMute': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'DeviceStatus': { 'Status': {}},
            'Freeze': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Input': { 
                'Status': {}, 
                'AllowedValues': ['Computer 1 (RGB)', 'Computer 1 (Component)', 'Computer 2 (RGB)', 'Computer 2 (Component)', 'HDMI 1', 'USB', 'LAN', 'HDMI 2', 'HDBaseT', 'Computer 1', 'Computer 2', 'Screen Mirroring', 'AirPlay']
            },
            'LampMode': { 'Status': {}, 'AllowedValues': ['Normal', 'Quiet', 'Long', 'Custom']},
            'LampUsage': { 'Status': {}},
            'MenuNavigation': { 'Status': {}, 'AllowedValues': ['Menu', 'Escape', 'Enter', 'Up', 'Down', 'Left', 'Right']},
            'OperationHours': { 'Status': {}},
            'Power': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'SplitScreen': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'SplitScreenSource': {
                'Parameters':['Side'], 
                'Status': {},
                'AllowedValues': ['Computer 1 (RGB)', 'Computer 1 (Component)', 'Computer 2 (RGB)', 'Computer 2 (Component)', 'HDMI 1', 'USB', 'LAN', 'HDMI 2', 'HDBaseT', 'Computer 1', 'Computer 2', 'Screen Mirroring', 'AirPlay'], 'ParameterValues': {'Side': ['Left', 'Right']}
            },
            'SplitScreenSwap': { 'Status': {}},
            'Volume': { 'Status': {}, 'AllowedValues': ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12', '13', '14', '15', '16', '17', '18', '19', '20']},
        }

        if self.Unidirectional == 'False':
            self.AddMatchString(re.compile(b'ASPECT=(00|10|20|30|40|50|60|A0)( 30)?\r:'), self.__MatchAspectRatio, None)
            self.AddMatchString(re.compile(b'MUTE=(ON|OFF)\r:'), self.__MatchAVMute, None)
            self.AddMatchString(re.compile(b'ERR=([0-9A-F]{2})\r:'), self.__MatchDeviceStatus, None)
            self.AddMatchString(re.compile(b'FREEZE=(ON|OFF)\r:'), self.__MatchFreeze, None)
            self.AddMatchString(re.compile(b'SOURCE=([0-9A-F]{2})\r:'), self.__MatchInput, None)
            self.AddMatchString(re.compile(b'LUMINANCE=(00|01|04|05)\r:'), self.__MatchLampMode, None)
            self.AddMatchString(re.compile(b'LAMP=([0-9]*)\r:'), self.__MatchLampUsage, None)
            self.AddMatchString(re.compile(b'ONTIME=([0-9]*)\r:'), self.__MatchOperationHours, None)
            self.AddMatchString(re.compile(b'PWR=(00|01|02|03|04|05|09)\r:'), self.__MatchPower, None)
            self.AddMatchString(re.compile(b'VOL=([0-9]{1,3})\r:'), self.__MatchVolume, None)
            #self.AddMatchString(re.compile(b'ERR\r:'), self.__MatchError, None)


    #Command String for Ethernet
    ################################################################################################################################
    def SetOnConnectedString(self):
        """
        Set OnConnectedString
        value: None
        qualifier: None

        """
        self.Send(b'ESC/VP.net\x10\x03\x00\x00\x00\x00') #ESC/VP.net%10%03%00%00%00%0

    def SetAspectRatio(self, value, qualifier):

        ValueStateValues = {
            'Normal' : '00', 
            '16:9' : '20', 
            'Auto' : '30', 
            'Full' : '40', 
            'H-Zoom' : '50', 
            'Native' : '60', 
            'V-Zoom' : 'A0',
            '4:3' : '10'
        }

        AspectRatioCmdString = 'ASPECT {0}\r'.format(ValueStateValues[value])
        self.__SetHelper('AspectRatio', AspectRatioCmdString, value, qualifier)

    def UpdateAspectRatio(self, value, qualifier):

        AspectRatioCmdString = 'ASPECT?\r'
        self.__UpdateHelper('AspectRatio', AspectRatioCmdString, value, qualifier)

    def __MatchAspectRatio(self, match, tag):

        ValueStateValues = {
            '00' : 'Normal', 
            '20' : '16:9', 
            '40' : 'Full', 
            '50' : 'H-Zoom', 
            '60' : 'Native', 
            'A0' : 'V-Zoom',
            '10' : '4:3'
        }

        if match.group(2) or match.group(1) == b'30':
            value = 'Auto'
        else:
            value = ValueStateValues.get(match.group(1).decode())
        if value:
            self.WriteStatus('AspectRatio', value, None)

    def SetAutoImage(self, value, qualifier):

        AutoImageCmdString = 'KEY 4A\r'
        self.__SetHelper('AutoImage', AutoImageCmdString, value, qualifier)
    def SetAVMute(self, value, qualifier):

        ValueStateValues = {
            'On' : 'ON', 
            'Off' : 'OFF'
        }

        AVMuteCmdString = 'MUTE {0}\r'.format(ValueStateValues[value])
        self.__SetHelper('AVMute', AVMuteCmdString, value, qualifier)

    def UpdateAVMute(self, value, qualifier):

        AVMuteCmdString = 'MUTE?\r'
        self.__UpdateHelper('AVMute', AVMuteCmdString, value, qualifier)

    def __MatchAVMute(self, match, tag):

        ValueStateValues = {
            'ON' : 'On', 
            'OFF' : 'Off'
        }

        value = ValueStateValues[match.group(1).decode()]
        self.WriteStatus('AVMute', value, None)

    def UpdateDeviceStatus(self, value, qualifier):

        DeviceStatusCmdString = 'ERR?\r'
        self.__UpdateHelper('DeviceStatus', DeviceStatusCmdString, value, qualifier)

    def __MatchDeviceStatus(self, match, tag):

        ValueStateValues = {
            '00' : 'Normal', 
            '01' : 'Fan Error',
            '03' : 'Lamp Failure at power on Error',
            '04' : 'Internal Temperature is Abnormally High Warning', 
            '07' : 'Lamp Cover Error', 
            '06' : 'Lamp Error', 
            '08' : 'Cinema Filter Error', 
            '09' : 'EDL Capacitor Disconnected Error', 
            '0A' : 'Auto Iris Error', 
            '0B' : 'Subsystem Error', 
            '0C' : 'Low Air Flow Error', 
            '0D' : 'Air Flow Error', 
            '0E' : 'Power Supply Error', 
            '0F' : 'Error Shutter Failure', 
            '10' : 'Cooling System Error', 
            '11' : 'Cooling System Error (Pump)',
            'FF' : 'Other Error'
        }

        code = match.group(1).decode()
        value = ValueStateValues.get(code, 'Unknown Error ({0})'.format(code))
        self.WriteStatus('DeviceStatus', value, None)

    def SetFreeze(self, value, qualifier):

        ValueStateValues = {
            'On' : 'ON', 
            'Off' : 'OFF'
        }

        FreezeCmdString = 'FREEZE {0}\r'.format(ValueStateValues[value])
        self.__SetHelper('Freeze', FreezeCmdString, value, qualifier)

    def UpdateFreeze(self, value, qualifier):

        FreezeCmdString = 'FREEZE?\r'
        self.__UpdateHelper('Freeze', FreezeCmdString, value, qualifier)

    def __MatchFreeze(self, match, tag):

        ValueStateValues = {
            'ON' : 'On', 
            'OFF' : 'Off'
        }

        value = ValueStateValues[match.group(1).decode()]
        self.WriteStatus('Freeze', value, None)

    def SetInput(self, value, qualifier):

        if value not in self.SetInputStateValues:
            self.Discard('Invalid Command for SetInput')
            return
        InputCmdString = 'SOURCE {0}\r'.format(self.SetInputStateValues[value])
        self.__SetHelper('Input', InputCmdString, value, qualifier)

    def UpdateInput(self, value, qualifier):

        InputCmdString = 'SOURCE?\r'
        self.__UpdateHelper('Input', InputCmdString, value, qualifier)

    def __MatchInput(self, match, tag):

        value = self.UpdateInputStateValues.get(match.group(1).decode())
        if value:
            self.WriteStatus('Input', value, None)

    def SetLampMode(self, value, qualifier):

        ValueStateValues = {
            'Normal' : '00', 
            'Quiet' : '01',
            'Long' : '04',
            'Custom' : '05'
        }

        LampModeCmdString = 'LUMINANCE {0}\r'.format(ValueStateValues[value])
        self.__SetHelper('LampMode', LampModeCmdString, value, qualifier)

    def UpdateLampMode(self, value, qualifier):

        LampModeCmdString = 'LUMINANCE?\r'
        self.__UpdateHelper('LampMode', LampModeCmdString, value, qualifier)

    def __MatchLampMode(self, match, tag):

        ValueStateValues = {
            '00' : 'Normal', 
            '01' : 'Quiet',
            '04' : 'Long',
            '05' : 'Custom'
        }

        value = ValueStateValues[match.group(1).decode()]
        self.WriteStatus('LampMode', value, None)

    def UpdateLampUsage(self, value, qualifier):

        LampUsageCmdString = 'LAMP?\r'
        self.__UpdateHelper('LampUsage', LampUsageCmdString, value, qualifier)

    def __MatchLampUsage(self, match, tag):

        value = int(match.group(1).decode())
        self.WriteStatus('LampUsage', value, None)

    def SetMenuNavigation(self, value, qualifier):

        ValueStateValues = {
            'Menu' : '03', 
            'Escape' : '05', 
            'Enter' : '16', 
            'Up' : '35', 
            'Down' : '36', 
            'Left' : '37', 
            'Right' : '38'
        }

        MenuNavigationCmdString = 'KEY {0}\r'.format(ValueStateValues[value])
        self.__SetHelper('MenuNavigation', MenuNavigationCmdString, value, qualifier)
    def UpdateOperationHours(self, value, qualifier):

        OperationHoursCmdString = 'ONTIME?\r'
        self.__UpdateHelper('OperationHours', OperationHoursCmdString, value, qualifier)

    def __MatchOperationHours(self, match, tag):

        value = int(match.group(1).decode())
        self.WriteStatus('OperationHours', value, None)

    def SetPower(self, value, qualifier):

        ValueStateValues = {
            'On'  : 'ON',
            'Off' : 'OFF'
        }

        PowerCmdString = 'PWR {0}\r'.format(ValueStateValues[value])
        self.__SetHelper('Power', PowerCmdString, value, qualifier)

    def UpdatePower(self, value, qualifier):


        PowerCmdString = 'PWR?\r'
        self.__UpdateHelper('Power', PowerCmdString, value, qualifier)

    def __MatchPower(self, match, tag):

        ValueStateValues = {
            '01' : 'On', 
            '00' : 'Off', 
            '02' : 'Warming Up', 
            '03' : 'Cooling Down',
            '04' : 'Off',
            '05' : 'Off',
            '09' : 'Off'
        }

        value = ValueStateValues[match.group(1).decode()]
        self.WriteStatus('Power', value, None)


    def SetSplitScreen(self, value, qualifier):

        ValueStateValues = {
            'On'  : '01', 
            'Off' : '00'
        }

        SplitScreenCmdString = 'SPS 01 {0}\r'.format(ValueStateValues[value])
        self.__SetHelper('SplitScreen', SplitScreenCmdString, value, qualifier)
    def SetSplitScreenSource(self, value, qualifier):

        SideStates = {
            'Left'  : '03', 
            'Right' : '04'
        }

        if value not in self.SetInputStateValues:
            self.Discard('Invalid Command for SetSplitScreenSource')
            return
        SplitScreenSourceCmdString = 'SPS {0} {1}\r'.format(SideStates[qualifier['Side']], self.SetInputStateValues[value])
        self.__SetHelper('SplitScreenSource', SplitScreenSourceCmdString, value, qualifier)
    def SetSplitScreenSwap(self, value, qualifier):

        SplitScreenSwapCmdString = 'SPS 05\r'
        self.__SetHelper('SplitScreenSwap', SplitScreenSwapCmdString, value, qualifier)
    def SetVolume(self, value, qualifier):

        ValueConstraints = {
            'Min' : 0,
            'Max' : 20
            }

        VolumeValues = {
            0   : '0',
            1   : '12',
            2   : '24',
            3   : '36',
            4   : '48',
            5   : '60',
            6   : '73',
            7   : '85',
            8   : '97',
            9   : '109',
            10  : '121',
            11  : '134',
            12  : '146',
            13  : '158',
            14  : '170',
            15  : '182',
            16  : '195',
            17  : '207',
            18  : '219',
            19  : '231',
            20  : '243'
        }

        if ValueConstraints['Min'] <= value <= ValueConstraints['Max']:
            VolumeCmdString = 'VOL {0}\r'.format(VolumeValues[value])
            self.__SetHelper('Volume', VolumeCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetVolume')

    def UpdateVolume(self, value, qualifier):

        VolumeCmdString = 'VOL?\r'
        self.__UpdateHelper('Volume', VolumeCmdString, value, qualifier)

    def __MatchVolume(self, match, tag):

        value = (int(match.group(1).decode()) // 12)
        self.WriteStatus('Volume', value, None)

    def __SetHelper(self, command, commandstring, value, qualifier):
        if command in self.Unsupported:
            self.Discard('Invalid Command for Set' + command)
            return
        self.Debug = True
        # Use SendAndWait to catch timeouts/errors during control
        # The delimiter ':' matches the end of Epson responses (e.g. "PWR=01\r:")
        self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag=b':')

    def __UpdateHelper(self, command, commandstring, value, qualifier):
        if command in self.Unsupported:
            self.Discard('Invalid Command for Update' + command)
            return
        if self.Unidirectional == 'True':
            self.Discard('Inappropriate Command ' + command)
        else:
            if self.initializationChk:
                self.OnConnected()
                self.initializationChk = False

            self.counter = self.counter + 1
            if self.counter > self.connectionCounter and self.connectionFlag:
                self.OnDisconnected()

            # This allows the Wrapper to see the timeout if the device is gone
            res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag=b':')
            
            if not res:
                # Optional: add log for a warning here
                pass
#

    def OnConnected(self):
        self.connectionFlag = True
        self.WriteStatus('ConnectionStatus', 'Connected')
        self.counter = 0

        if 'Serial' not in self.ConnectionType:
            self.SetOnConnectedString()

    def OnDisconnected(self):
        self.WriteStatus('ConnectionStatus', 'Disconnected')
        self.connectionFlag = False

    def __SetInputs(self, names):

        self.SetInputStateValues = {name: self.InputCodes[name] for name in names}
        self.Commands['Input']['AllowedValues'] = list(names)
        self.Commands['SplitScreenSource']['AllowedValues'] = list(names)

    # One DEVICE_INFO["model_support"] group: its inputs and the commands it lacks.
    def __UseModelSupport(self, group):

        self.__SetInputs(group['values']['Input'])
        self.Unsupported = set(group.get('unsupported', []))

    ######################################################    
    # RECOMMENDED not to modify the code below this point
    ######################################################

	# Send Control Commands
    def Set(self, command, value, qualifier=None):
        method = getattr(self, 'Set%s' % command)
        if method is not None and callable(method):
            method(value, qualifier)
        else:
            print(command, 'does not support Set.')


    # Send Update Commands
    def Update(self, command, qualifier=None):
        method = getattr(self, 'Update%s' % command)
        if method is not None and callable(method):
            method(None, qualifier)
        else:
            print(command, 'does not support Update.')

    # This method is to tie an specific command with a parameter to a call back method
    # when its value is updated. It sets how often the command will be query, if the command
    # have the update method.
    # If the command doesn't have the update feature then that command is only used for feedback 
    def SubscribeStatus(self, command, qualifier, callback):
        Command = self.Commands.get(command)
        if Command:
            if command not in self.Subscription:
                self.Subscription[command] = {'method':{}}
        
            Subscribe = self.Subscription[command]
            Method = Subscribe['method']
        
            if qualifier:
                for Parameter in Command['Parameters']:
                    try:
                        Method = Method[qualifier[Parameter]]
                    except:
                        if Parameter in qualifier:
                            Method[qualifier[Parameter]] = {}
                            Method = Method[qualifier[Parameter]]
                        else:
                            return
        
            Method['callback'] = callback
            Method['qualifier'] = qualifier    
        else:
            print(command, 'does not exist in the module')

    # This method is to check the command with new status have a callback method then trigger the callback
    def NewStatus(self, command, value, qualifier):
        if command in self.Subscription :
            Subscribe = self.Subscription[command]
            Method = Subscribe['method']
            Command = self.Commands[command]
            if qualifier:
                for Parameter in Command['Parameters']:
                    try:
                        Method = Method[qualifier[Parameter]]
                    except:
                        break
            if 'callback' in Method and Method['callback']:
                Method['callback'](command, value, qualifier)  

    # Save new status to the command
    def WriteStatus(self, command, value, qualifier=None):
        self.counter = 0
        if not self.connectionFlag:
            self.OnConnected()
        Command = self.Commands[command]
        Status = Command['Status']
        if qualifier:
            for Parameter in Command['Parameters']:
                try:
                    Status = Status[qualifier[Parameter]]
                except KeyError:
                    if Parameter in qualifier:
                        Status[qualifier[Parameter]] = {}
                        Status = Status[qualifier[Parameter]]
                    else:
                        return  
        try:
            if Status['Live'] != value:
                Status['Live'] = value
                self.NewStatus(command, value, qualifier)
        except:
            Status['Live'] = value
            self.NewStatus(command, value, qualifier)

    # Read the value from a command.
    def ReadStatus(self, command, qualifier=None):
        Command = self.Commands[command]
        Status = Command['Status']
        if qualifier:
            for Parameter in Command['Parameters']:
                try:
                    Status = Status[qualifier[Parameter]]
                except KeyError:
                    return None
        try:
            return Status['Live']
        except:
            return None

    def __ReceiveData(self, interface, data):
        #print("Epson Received Data: {}".format(data))
    # handling incoming unsolicited data
        self._ReceiveBuffer += data
        # check incoming data if it matched any expected data from device module
        if self.CheckMatchedString() and len(self._ReceiveBuffer) > 10000:
            self._ReceiveBuffer = b''

    # Add regular expression so that it can be check on incoming data from device.
    def AddMatchString(self, regex_string, callback, arg):
        if regex_string not in self._compile_list:
            self._compile_list[regex_string] = {'callback': callback, 'para':arg}
                

   # Check incoming unsolicited data to see if it was matched with device expectancy.
    def CheckMatchedString(self):
        for regexString in self._compile_list:
            while True:
                result = re.search(regexString, self._ReceiveBuffer)
                if result:
                    self._compile_list[regexString]['callback'](result, self._compile_list[regexString]['para'])
                    self._ReceiveBuffer = self._ReceiveBuffer.replace(result.group(0), b'')
                else:
                    break
        return True

class SerialClass(SerialInterface, DeviceClass):

    def __init__(self, Host, Port, Baud=9600, Data=8, Parity='None', Stop=1, FlowControl='Off', CharDelay=0, Mode='RS232', Model =None):
        SerialInterface.__init__(self, Host, Port, Baud, Data, Parity, Stop, FlowControl, CharDelay, Mode)
        self.ConnectionType = 'Serial'
        DeviceClass.__init__(self)
        # Check if Model belongs to a subclass
        if len(self.Models) > 0:
            if Model not in self.Models: 
                print('Model mismatch')              
            else:
                self.Models[Model]()

    def Error(self, message):
        portInfo = 'Host Alias: {0}, Port: {1}'.format(self.Host.DeviceAlias, self.Port)
        print('Module: {}'.format(__name__), portInfo, 'Error Message: {}'.format(message[0]), sep='\r\n')
  
    def Discard(self, message):
        self.Error([message])

class SerialOverEthernetClass(EthernetClientInterface, DeviceClass):

    def __init__(self, Hostname, IPPort, Protocol='TCP', ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = 'Serial'
        DeviceClass.__init__(self) 
        # Check if Model belongs to a subclass       
        if len(self.Models) > 0:
            if Model not in self.Models: 
                print('Model mismatch')              
            else:
                self.Models[Model]()

    def Connect(self, *args, **kwargs):
        result = EthernetClientInterface.Connect(self, *args, **kwargs)
        if result == 'Connected':
            self.Send(b'ESC/VP.net\x10\x03\x00\x00\x00\x00')
        return result

    def Error(self, message):
        portInfo = 'IP Address/Host: {0}:{1}'.format(self.Hostname, self.IPPort)
        print('Module: {}'.format(__name__), portInfo, 'Error Message: {}'.format(message[0]), sep='\r\n')
  
    def Discard(self, message):
        self.Error([message])

    def Disconnect(self):
        EthernetClientInterface.Disconnect(self)
        self.OnDisconnected()


class EthernetClass(EthernetClientInterface, DeviceClass):

    def __init__(self, Hostname, IPPort, Protocol='TCP', ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = 'Ethernet'
        DeviceClass.__init__(self) 
        # Check if Model belongs to a subclass       
        if len(self.Models) > 0:
            if Model not in self.Models: 
                print('Model mismatch')              
            else:
                self.Models[Model]()

    def Connect(self, *args, **kwargs):
        result = EthernetClientInterface.Connect(self, *args, **kwargs)
        if result == 'Connected':
            self.Send(b'ESC/VP.net\x10\x03\x00\x00\x00\x00')
        return result

    def Error(self, message):
        portInfo = 'IP Address/Host: {0}:{1}'.format(self.Hostname, self.IPPort)
        print('Module: {}'.format(__name__), portInfo, 'Error Message: {}'.format(message[0]), sep='\r\n')
  
    def Discard(self, message):
        self.Error([message])

    def Disconnect(self):
        EthernetClientInterface.Disconnect(self)
        self.OnDisconnected()