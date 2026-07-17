from extronlib.interface import SerialInterface, EthernetClientInterface
from extronlib.system import ProgramLog, Wait
import re

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "display",
    "models": ["INF6540e", "INF7540e", "INF8640e"],
    "connection": {
        "com_type": "Serial",
        "protocol": "",
        "host": "processor1",
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_Projector1",
        "lbl_name": "Lbl_Proj_Model_Proj1",
        "gve_id": "Proj1",
        "name": "Display - INF6540e",
        "device_id": None,
        "keep_alive_command": "Power",
        "keep_alive_interval": 30,
        "keep_alive_trigger": None,
        "manual_disconnect": False,
        "user": "",
        "password": "",  # site-specific — blank
    },
}


class DeviceClass:
    def __init__(self):

        self.Unidirectional = 'False'
        self.connectionCounter = 15
        self.DefaultResponseTimeout = 0.3
        self.Subscription = {}
        self.counter = 0
        self.connectionFlag = True
        self.initializationChk = True
        self.Debug = False
        self.Models = {}

        self.Commands = {
            'ConnectionStatus': {'Status': {}},
            'AspectRatio': { 'Status': {}, 'AllowedValues': ['Full (16:9)', 'Normal (4:3)', 'P2P']},
            'AudioMute': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Input': { 'Status': {}, 'AllowedValues': ['OPS', 'AV', 'HDMI', 'HDMI 1', 'HDMI 2', 'HDMI 3', 'HDMI 4', 'VGA', 'DisplayPort', 'Android', 'Android+']},
            'Power': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Volume': { 'Status': {}},
        }

    def SetAspectRatio(self, value, qualifier):

        ValueStateValues = {
            'Full (16:9)'        : ':01S;000\r',
            'Normal (4:3)'       : ':01S;001\r',
            'P2P'               : ':01S;002\r',
        }

        if value in ValueStateValues:
            AspectRatioCmdString = ValueStateValues[value]
            self.__SetHelper('AspectRatio', AspectRatioCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetAspectRatio')

    def SetAudioMute(self, value, qualifier):

        ValueStateValues = {
            'On':  ':01S9001\r', 
            'Off': ':01S9000\r'
        }

        if value in ValueStateValues:
            AudioMuteCmdString = ValueStateValues[value]
            self.__SetHelper('AudioMute', AudioMuteCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetAudioMute')

    def UpdateAudioMute(self, value, qualifier):

        ValueStateValues = {
            '1' : 'On', 
            '0' : 'Off'
        }

        AudioMuteCmdString = ':01G9000\r'
        res = self.__UpdateHelper('AudioMute', AudioMuteCmdString, value, qualifier)
        try:
            value = ValueStateValues[res[7]]
            self.WriteStatus('AudioMute', value, qualifier)
        except (KeyError, IndexError):
            self.Error(['Audio Mute: Invalid/unexpected response'])

    def SetInput(self, value, qualifier):

        ValueStateValues = {
            'OPS'                    : ':01S:103\r',
            'AV'                     : ':01S:003\r',
            'HDMI'                   : ':01S:001\r',
            'HDMI 1'                 : ':01S:001\r',
            'HDMI 2'                 : ':01S:002\r',
            'HDMI 3'                 : ':01S:021\r',
            'HDMI 4'                 : ':01S:022\r',
            'VGA'                    : ':01S:000\r',
            'DisplayPort'            : ':01S:007\r',
            'Android'                : ':01S:101\r',
            'Android+'                : ':01S:102\r',
        }

        if value in ValueStateValues:
            InputCmdString = ValueStateValues[value]
            self.__SetHelper('Input', InputCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetInput')

    def UpdateInput(self, value, qualifier):

        ValueStateValues = {
            '103': 'OPS',
            '003': 'AV',
            '001': 'HDMI 1',
            '002': 'HDMI 2',
            '021': 'HDMI 3',
            '022': 'HDMI 4',
            '000': 'VGA',
            '007': 'DisplayPort',
            '101': 'Android',
            '102': 'Android+',
        }

        InputCmdString = ':01G:000\r'
        res = self.__UpdateHelper('Input', InputCmdString, value, qualifier)
        print("INF8640e Res on Input: {}".format(res))
        try:
            input_code = res[5:8]
            if input_code in ValueStateValues:
                value = ValueStateValues[input_code]
                print("INF8640e Value on Input: {}".format(value))
                self.WriteStatus('Input', value, qualifier)
            else:
                raise KeyError("Input code not found in ValueStateValues")
        except IndexError:
            self.Error(['Input: Invalid/unexpected response'])
        except KeyError:
            self.Error(['Input: Invalid input code'])

    def SetPower(self, value, qualifier):

        ValueStateValues = {
            'On' :  ':01S0003\r', 
            'Off' : ':01S0002\r'
        }

        if value in ValueStateValues:
            PowerCmdString = ValueStateValues[value]
            self.__SetHelper('Power', PowerCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPower')

    def UpdatePower(self, value, qualifier):
        ValueStateValues = {
            '1': 'On',
            '2': 'Off',
            '0': 'Standby',
        }

        PowerCmdString = ':01G0000\r'
        res = self.__UpdateHelper('Power', PowerCmdString, value, qualifier)

        try:
            print("INF8640e Res on Power: {}".format(res))
            # Using get with a default value to handle the case where res[-1] is not in ValueStateValues
            value = ValueStateValues.get(res[7], 'Unknown')
            self.WriteStatus('Power', value, qualifier)
            print("INF8640e Value on Power: {}".format(value))
        except IndexError:
            self.Error(['Power: Invalid/unexpected response'])
        except KeyError:
            self.Error(['Power: Invalid power state code'])


    def SetVolume(self, value, qualifier):

        ValueConstraints = {
            'Min' : 0,
            'Max' : 100
        }

        if ValueConstraints['Min'] <= value <= ValueConstraints['Max']:
            VolumeCmdString = ':01S8{0:03}\r'.format(value)
            self.__SetHelper('Volume', VolumeCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetVolume')

    def UpdateVolume(self, value, qualifier):

        VolumeCmdString = ':01G8000\r'
        res = self.__UpdateHelper('Volume', VolumeCmdString, value, qualifier)
        try:
            print("INF8640e Res on Volume: {}".format(res))
            value = int(res[5:8])
            self.WriteStatus('Volume', value, qualifier)
            print("INF8640e Value on Volume: {}".format(value))
        except IndexError:
            self.Error(['Volume: Invalid/unexpected response'])
        except KeyError:
            self.Error(['Volume: Invalid power state code'])

    def __CheckResponseForErrors(self, sourceCmdName, response):

        if '401-\r' in response:
            self.Error(['{}: Invalid command'.format(sourceCmdName)])
            response = ''
        return response

    def __SetHelper(self, command, commandstring, value, qualifier):

        self.Debug = True

        if self.Unidirectional == 'True':
            self.Send(commandstring)
        else:
            res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag='\r')
            if not res:
                self.Error(['{}: Invalid/unexpected response'.format(command)])
            else:
                res = self.__CheckResponseForErrors(command, res.decode())

    def __UpdateHelper(self, command, commandstring, value, qualifier):

        if self.Unidirectional == 'True':
            self.Discard('Inappropriate Command ' + command)
            return ''
        else:
            if self.initializationChk:
                self.OnConnected()
                self.initializationChk = False

            self.counter = self.counter + 1
            if self.counter > self.connectionCounter and self.connectionFlag:
                self.OnDisconnected()

            res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag='\r')
            if not res:
                return ''
            else:
                return self.__CheckResponseForErrors(command, res.decode())

    def OnConnected(self):

        self.connectionFlag = True
        self.WriteStatus('ConnectionStatus', 'Connected')
        self.counter = 0

    def OnDisconnected(self):

        self.WriteStatus('ConnectionStatus', 'Disconnected')
        self.connectionFlag = False

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

    # Send Update Commands
    def Update(self, command, qualifier=None):
        method = getattr(self, 'Update%s' % command, None)
        if method is not None and callable(method):
            method(None, qualifier)
        else:
            raise AttributeError(command + 'does not support Update.')

    # This method is to tie an specific command with a parameter to a call back method
    # when its value is updated. It sets how often the command will be query, if the command
    # have the update method.
    # If the command doesn't have the update feature then that command is only used for feedback 
    def SubscribeStatus(self, command, qualifier, callback):
        Command = self.Commands.get(command, None)
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
            raise KeyError('Invalid command for SubscribeStatus ' + command)

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
        Command = self.Commands.get(command, None)
        if Command:
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
        else:
            raise KeyError('Invalid command for ReadStatus: ' + command)

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

    def Error(self, message):
        portInfo = 'IP Address/Host: {0}:{1}'.format(self.Hostname, self.IPPort)
        print('Module: {}'.format(__name__), portInfo, 'Error Message: {}'.format(message[0]), sep='\r\n')
  
    def Discard(self, message):
        self.Error([message])

    def Disconnect(self):
        EthernetClientInterface.Disconnect(self)
        self.OnDisconnected()