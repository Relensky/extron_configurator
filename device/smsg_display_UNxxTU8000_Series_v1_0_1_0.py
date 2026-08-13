from extronlib.interface import SerialInterface, EthernetClientInterface
from extronlib.system import Wait, ProgramLog, GetUnverifiedContext
import base64
import struct
import urllib.error
import urllib.request
import json

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "display",
    "models": [
        "UN43TU8000",
        "UN50TU8000",
        "UN55TU8000",
        "UN65TU8000",
        "UN75TU8000",
        "UN85TU8000",
    ],
    "connection": {
        "com_type": "HTTP",
        "protocol": "TCP",
        "net_port": 1516,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",  # site-specific — blank
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_Projector1",
        "lbl_name": "Lbl_Proj_Model_Proj1",
        "gve_id": "Proj1",
        "name": "Display - UN43TU8000",
        "device_id": None,
        "keep_alive_command": "Power",
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
    "http": {
        "protocol": "TCP",
        "net_port": 1516,
        "service_port": 0,
        "keep_alive_command": "Input",  # this connection's command set differs
    },
}


class DeviceSerialClass:
    def __init__(self):

        self.Debug = False
        self.Models = {}

        self.Commands = {
            'AspectRatio': { 'Status': {}, 'AllowedValues': ['4:3', '16:9']},
            'AudioMute': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Channel': { 'Status': {}, 'AllowedValues': ['Up', 'Down']},
            'Input': { 'Status': {}, 'AllowedValues': ['TV', 'AV', 'HDMI 1', 'HDMI 2', 'HDMI 3']},
            'Keypad': { 'Status': {}, 'AllowedValues': ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']},
            'MenuNavigation': { 'Status': {}, 'AllowedValues': ['Up', 'Down', 'Left', 'Right', 'Menu', 'Enter', 'Return', 'Exit']},
            'Power': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Volume': { 'Status': {}},
        }

    def build(self, cmd1, cmd2, cmd3, value):
        command_string = struct.pack('6B', 0x08, 0x22, cmd1, cmd2, cmd3, value)
        checksum = bytes([(~sum(command_string) & 0xFF) + 1])

        return command_string + checksum

    def SetAspectRatio(self, value, qualifier):

        ValueStateValues = {
            '4:3':      0x04,
            '16:9':     0x00,
            'Custom':   0x0B
        }

        if value in ValueStateValues:
            AspectRatioCmdString = self.build(0x0B, 0x0A, 0x01, ValueStateValues[value])
            self.__SetHelper('AspectRatio', AspectRatioCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetAspectRatio')
            
    def SetAudioMute(self, value, qualifier):

        AudioMuteCmdString = self.build(0x02, 0x00, 0x00, 0x00)
        self.__SetHelper('AudioMute', AudioMuteCmdString, value, qualifier)

    def SetChannel(self, value, qualifier):

        ValueStateValues = {
            'Up':   0x01,
            'Down': 0x02
        }

        if value in ValueStateValues:
            ChannelCmdString = self.build(0x03, 0x00, ValueStateValues[value], 0x00)
            self.__SetHelper('Channel', ChannelCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetChannel')

    def SetInput(self, value, qualifier):

        ValueStateValues = {
            'TV':       (0x00, 0x00),
            'AV':       (0x01, 0x00),
            'HDMI 1':   (0x05, 0x00),
            'HDMI 2':   (0x05, 0x01),
            'HDMI 3':   (0x05, 0x02)
        }

        if value in ValueStateValues:
            InputCmdString = self.build(0x0A, 0x00, ValueStateValues[value][0], ValueStateValues[value][1])
            self.__SetHelper('Input', InputCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetInput')

    def SetKeypad(self, value, qualifier):

        ValueStateValues = {
            '0': 0x11,
            '1': 0x04,
            '2': 0x05,
            '3': 0x06,
            '4': 0x08,
            '5': 0x09,
            '6': 0x0A,
            '7': 0x0C,
            '8': 0x0D,
            '9': 0x0E
        }

        if 0 <= int(value) <= 9:
            KeypadCmdString = self.build(0x0D, 0x00, 0x00, ValueStateValues[value])
            self.__SetHelper('Keypad', KeypadCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetKeypad')

    def SetMenuNavigation(self, value, qualifier):

        ValueStateValues = {
            'Up':     0x60,
            'Down':   0x61,
            'Left':   0x65,
            'Right':  0x62,
            'Menu':   0x1A,
            'Enter':  0x2E,
            'Return': 0x58,
            'Exit':   0x2D
        }

        if value in ValueStateValues:
            MenuNavigationCmdString = self.build(0x0D, 0x00, 0x00, ValueStateValues[value])
            self.__SetHelper('MenuNavigation', MenuNavigationCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetMenuNavigation')

    def SetPower(self, value, qualifier):

        ValueStateValues = {
            'On':   0x02,
            'Off':  0x01
        }

        if value in ValueStateValues:
            PowerCmdString = self.build(0x00, 0x00, 0x00, ValueStateValues[value])
            self.__SetHelper('Power', PowerCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPower')

    def SetVolume(self, value, qualifier):

        if 0 <= value <= 100:
            VolumeCmdString = self.build(0x01, 0x00, 0x00, int(value))
            self.__SetHelper('Volume', VolumeCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetVolume')

    def __SetHelper(self, command, commandstring, value, qualifier):
        self.Debug = True

        self.Send(commandstring)

    ######################################################    
    # RECOMMENDED not to modify the code below this point
    ######################################################

    # Send Control Commands
    def Set(self, command, value, qualifier=None):
        method = getattr(self, 'Set%s' % command, None)
        if method is not None and callable(method):
            method(value, qualifier)
        else:
            raise AttributeError(command + 'does not support Set.')

class DeviceHTTPClass:

    def __init__(self, ipAddress, port, SSLVerifyMode='On'):

        if SSLVerifyMode == 'Off':
            self._context = GetUnverifiedContext()
        else:
            self._context = None

        self.RootURL = 'https://{0}:{1}/'.format(ipAddress, port)
        self.Opener = urllib.request.build_opener(urllib.request.HTTPBasicAuthHandler(), urllib.request.HTTPSHandler(context=self._context))

        self.Debug = False
        self.Models = {}

        self.Commands = {
            'AspectRatio': { 'Status': {}, 'AllowedValues': ['4:3', '16:9']},
            'AudioMute': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Channel': { 'Status': {}, 'AllowedValues': ['Up', 'Down']},
            'Input': { 'Status': {}, 'AllowedValues': ['TV', 'AV', 'HDMI 1', 'HDMI 2', 'HDMI 3']},
            'Keypad': { 'Status': {}, 'AllowedValues': ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']},
            'MenuNavigation': { 'Status': {}, 'AllowedValues': ['Up', 'Down', 'Left', 'Right', 'Menu', 'Enter', 'Return', 'Exit']},
            'PowerOff': { 'Status': {}},
            'RefreshToken': { 'Status': {}},
            'Volume': { 'Status': {}},
        }

        self.AccessToken = None

    def SetAspectRatio(self, value, qualifier):

        ValueStateValues = {
            '4:3'  : '4:3',
            '16:9' : '16:9'
        }

        if value in ValueStateValues and self.AccessToken:
            data = {
                'jsonrpc' : '2.0',
                'method' : 'pictureSizeControl',
                'params' : {
                    'AccessToken' : self.AccessToken,
                    'pictureSize' : ValueStateValues[value]
                },
                'id' : 1
            }

            self.__SetHelper('AspectRatio', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetAspectRatio')

    def SetAudioMute(self, value, qualifier):

        ValueStateValues = {
            'On'  : 'muteOn',
            'Off' : 'muteOff'
        }

        if value in ValueStateValues and self.AccessToken:
            data = {
                'jsonrpc': '2.0',
                'method': 'muteControl',
                'params': {
                    'AccessToken': self.AccessToken,
                    'mute': ValueStateValues[value]
                },
                'id': 1
            }

            self.__SetHelper('AudioMute', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetAudioMute')

    def SetChannel(self, value, qualifier):

        ValueStateValues = {
            'Up'    : 'channelUp',
            'Down'  : 'channelDn'
        }

        if value in ValueStateValues and self.AccessToken:
            data = {
                'jsonrpc': '2.0',
                'method': 'channelUpDnControl',
                'params': {
                    'AccessToken': self.AccessToken,
                    'control': ValueStateValues[value]
                },
                'id': 1
            }

            self.__SetHelper('Channel', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetChannel')

    def SetInput(self, value, qualifier):

        ValueStateValues = {
            'TV'     : 'TV',
            'AV'     : 'AV1',
            'HDMI 1' : 'HDMI1', 
            'HDMI 2' : 'HDMI2',
            'HDMI 3' : 'HDMI3'
        }

        if value in ValueStateValues and self.AccessToken:
            data = {
                'jsonrpc': '2.0',
                'method': 'inputSourceControl',
                'params': {
                    'AccessToken': self.AccessToken,
                    'inputSource': ValueStateValues[value]
                },
                'id': 1
            }

            self.__SetHelper('Input', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetInput')

    def SetKeypad(self, value, qualifier):

        ValueStateValues = {
            '0' : 'number0', 
            '1' : 'number1', 
            '2' : 'number2', 
            '3' : 'number3', 
            '4' : 'number4', 
            '5' : 'number5', 
            '6' : 'number6', 
            '7' : 'number7', 
            '8' : 'number8', 
            '9' : 'number9'
        }

        if value in ValueStateValues and self.AccessToken:
            data = {
                'jsonrpc': '2.0',
                'method': 'remoteKeyControl',
                'params': {
                    'AccessToken': self.AccessToken,
                    'remoteKey': ValueStateValues[value]
                },
                'id': 1
            }

            self.__SetHelper('Keypad', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetKeypad')

    def SetMenuNavigation(self, value, qualifier):

        ValueStateValues = {
            'Up'     : 'cursorUp',
            'Down'   : 'cursorDn',
            'Left'   : 'cursorLeft',
            'Right'  : 'cursorRight',
            'Menu'   : 'menu',
            'Enter'  : 'enter',
            'Return' : 'return',
            'Exit'   : 'exit'
        }

        if value in ValueStateValues and self.AccessToken:
            data = {
                'jsonrpc': '2.0',
                'method': 'remoteKeyControl',
                'params': {
                    'AccessToken': self.AccessToken,
                    'remoteKey': ValueStateValues[value]
                },
                'id': 1
            }

            self.__SetHelper('MenuNavigation', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetMenuNavigation')

    def SetPowerOff(self, value, qualifier):

        if self.AccessToken:
            data = {
                'jsonrpc': '2.0',
                'method': 'powerControl',
                'params': {
                    'AccessToken': self.AccessToken,
                    'power': 'powerOff'
                },
                'id': 1
            }

            self.__SetHelper('PowerOff', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetPowerOff')

    def SetRefreshToken(self, value, qualifier):

        data = {
            'jsonrpc' : '2.0',
            'method' : 'createAccessToken',
            'id' : 1
        }

        res = self.__SetHelper('RefreshToken', value, qualifier, data)
        if res:
            try:
                self.AccessToken = res['result']['AccessToken']
            except KeyError:
                self.Error(['Refresh Token: Invalid/unexpected response'])

    def SetVolume(self, value, qualifier):

        if 0 <= value <= 100 and self.AccessToken:
            data = {
                'jsonrpc': '2.0',
                'method': 'directVolumeControl',
                'params': {
                    'AccessToken': self.AccessToken,
                    'volume': value
                },
                'id': 1
            }

            self.__SetHelper('Volume', value, qualifier, data)
        else:
            self.Discard('Invalid Command for SetVolume')

    def __CheckResponseForErrors(self, sourceCmdName, response):

        try:
            res = json.loads(response.read().decode())
            if 'error' in res:
                self.Error(['{0}: {1}'.format(sourceCmdName, res['error']['message'])])
                return ''
            return res
        except Exception:
            self.Error(['{}: Invalid/unexpected response'.format(sourceCmdName)])

    def __SetHelper(self, command, value, qualifier, data=None):

        self.Debug = True

        if command == 'RefreshToken':
            responseTimeout = 30
        else:
            responseTimeout = 1
        url = self.RootURL
        data = json.dumps(data).encode()

        headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        }

        my_request = urllib.request.Request(url, data=data, headers=headers, method='POST')

        try:
            res = self.Opener.open(my_request, timeout=responseTimeout)  # open() returns a http.client.HTTPResponse object if successful
        except urllib.error.HTTPError as err:  # includes HTTP status codes 101, 300-505
            self.Error(['{0} {1} - {2}'.format(command, err.code, err.reason)])
            res = ''
        except urllib.error.URLError as err:  # received if can't reach the server (times out)
            self.Error(['{0} {1}'.format(command, err.reason)])
            res = ''
        except Exception as err:  # includes HTTP status code 100 and any invalid status code
            res = ''
        else:
            if res.status not in (200, 202):
                self.Error(['{0} {1} - {2}'.format(command, res.status, res.msg)])
                res = ''
            else:
                res = self.__CheckResponseForErrors(command, res)
        return res

    ######################################################    
    # RECOMMENDED not to modify the code below this point
    ######################################################

    # Send Control Commands
    def Set(self, command, value, qualifier=None):
        method = getattr(self, 'Set%s' % command, None)
        if method is not None and callable(method):
            method(value, qualifier)
        else:
            raise AttributeError(command + 'does not support Set.')

class SerialClass(SerialInterface, DeviceSerialClass):

    def __init__(self, Host, Port, Baud=9600, Data=8, Parity='None', Stop=1, FlowControl='Off', CharDelay=0, Mode='RS232', Model =None):
        SerialInterface.__init__(self, Host, Port, Baud, Data, Parity, Stop, FlowControl, CharDelay, Mode)
        self.ConnectionType = 'Serial'
        DeviceSerialClass.__init__(self)
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

class SerialOverEthernetClass(EthernetClientInterface, DeviceSerialClass):

    def __init__(self, Hostname, IPPort, Protocol='TCP', ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = 'Serial'
        DeviceSerialClass.__init__(self) 
        # Check if Model belongs to a subclass       
        if len(self.Models) > 0:
            if Model not in self.Models: 
                print('Model mismatch')              
            else:
                self.Models[Model]()

    def Error(self, message):
        portInfo = 'IP Address/Host: {0}:{1}'.format(self.Hostname, self.IPPort)
        print('Module: {}'.format(__name__), portInfo, 'Error Message: {}'.format(message[0]), sep='\r\n')
  
    def Discard(self, message):
        self.Error([message])

    def Disconnect(self):
        EthernetClientInterface.Disconnect(self)
        self.OnDisconnected()

class HTTPClass(DeviceHTTPClass):

    def __init__(self, ipAddress, port, deviceUsername=None, devicePassword=None, Model=None, SSLVerifyMode='On'):
        self.ConnectionType = 'HTTP'
        DeviceHTTPClass.__init__(self, ipAddress, port, SSLVerifyMode)
        # Check if Model belongs to a subclass      
        if len(self.Models) > 0:
            if Model not in self.Models:
                print('Model mismatch')             
            else:
                self.Models[Model]()

    def Error(self, message):
        portInfo = 'IP Address/Host: {0}'.format(self.RootURL)
        print('Module: {}'.format(__name__), portInfo, 'Error Message: {}'.format(message[0]), sep='\r\n')
  
    def Discard(self, message):
        self.Error([message])