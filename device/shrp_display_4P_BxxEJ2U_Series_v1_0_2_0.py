# pylint: disable=consider-using-f-string
# pylint: disable=C0111,C0302
# pylint: disable=invalid-name
# pylint: disable=missing-module-docstring
# pylint: disable=missing-class-docstring
# pylint: disable=missing-function-docstring
from extronlib.interface import SerialInterface, EthernetClientInterface
from extronlib.system import ProgramLog
import re

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "display",
    "models": [
        "4P-B75EJ2U",
        "4P-B65EJ2U",
        "4P-B55EJ2U",
        "4P-B50EJ2U",
        "4P-B43EJ2U",
        "4P-B86EJ2U",
    ],
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 10008,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",  # site-specific — blank
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_Projector1",
        "lbl_name": "Lbl_Proj_Model_Proj1",
        "gve_id": "Proj1",
        "name": "Display - 4P-B75EJ2U",
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
}


class DeviceSerialClass:
    def __init__(self):

        self.Unidirectional = 'False'
        self.connectionCounter = 15
        self.DefaultResponseTimeout = 0.3
        self.Subscription = {}
        self.ReceiveData = self.__ReceiveData
        self.__receiveBuffer = b''
        self.__maxBufferSize = 2048
        self.__matchStringDict = {}
        self.counter = 0
        self.connectionFlag = True
        self.initializationChk = True
        self.Debug = False
        self.deviceUsername = None
        self.devicePassword = None
        self.Authenticated = 'Not Needed'
        self.AuthenticatedError = False
        self.Models = {}

        self.Commands = {
            'AspectRatio': { 'Status': {}, 'AllowedValues': ['Auto', 'Normal', 'Zoom', 'Dot by Dot', '4:3', '14:9', '16:9']},
            'ConnectionStatus': {'Status': {}},
            'Input': { 'Status': {}, 'AllowedValues': ['TV', 'Composite', 'HDMI 1', 'HDMI 2', 'HDMI 3', 'USB', 'Home']},
            'UsageTime': { 'Status': {}},
            'Mute': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Power': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'SerialNumber': { 'Status': {}},
            'Volume': { 'Status': {}},
        }

    def SetAspectRatio(self, value, qualifier):

        ValueStateValues = {
            'Auto'      : '1',
            'Normal'    : '2',
            'Zoom'      : '3',
            'Dot by Dot': '4',
            '4:3'       : '5',
            '14:9'      : '6',
            '16:9'      : '7'
        }

        if value in ValueStateValues:
            AspectRatioCmdString = 'WIDE{:>4}\r'.format(ValueStateValues[value])
            self.__SetHelper('AspectRatio', AspectRatioCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetAspectRatio')

    def UpdateAspectRatio(self, value, qualifier):

        ValueStateValues = {
            1: 'Auto',
            2: 'Normal',
            3: 'Zoom',
            4: 'Dot by Dot',
            5: '4:3',
            6: '14:9',
            7: '16:9'
        }

        AspectRatioCmdString = 'WIDE   ?\r'
        res = self.__UpdateHelper('AspectRatio', AspectRatioCmdString, value, qualifier)
        if res:
            try:
                value = ValueStateValues[int(res)]
                self.WriteStatus('AspectRatio', value, qualifier)
            except (KeyError, ValueError):
                self.Error(['Aspect Ratio: Invalid/unexpected response'])

    def SetInput(self, value, qualifier):

        ValueStateValues = {
            'TV'        : '0',
            'Composite' : '1',
            'HDMI 1'    : '2',
            'HDMI 2'    : '3',
            'HDMI 3'    : '4',
            'USB'       : '5',
            'Home'      : '6'
        }

        if value in ValueStateValues:
            InputCmdString = 'INPS{:>4}\r'.format(ValueStateValues[value])
            self.__SetHelper('Input', InputCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetInput')

    def UpdateInput(self, value, qualifier):

        ValueStateValues = {
            0: 'TV',
            1: 'Composite',
            2: 'HDMI 1',
            3: 'HDMI 2',
            4: 'HDMI 3',
            5: 'USB',
            6: 'Home'
        }

        InputCmdString = 'INPS   ?\r'
        res = self.__UpdateHelper('Input', InputCmdString, value, qualifier)
        if res:
            try:
                value = ValueStateValues[int(res)]
                self.WriteStatus('Input', value, qualifier)
            except (KeyError, ValueError):
                self.Error(['Input: Invalid/unexpected response'])

    def UpdateUsageTime(self, value, qualifier):
        UsageTimeCmdString = 'UTIM   ?\r'
        res = self.__UpdateHelper('UsageTime', UsageTimeCmdString, value, qualifier)
        if res:
            try:
                value = int(res)
                if value is not None:
                    self.WriteStatus('UsageTime', value, None)
            except ValueError:
                pass

    def SetMute(self, value, qualifier):

        ValueStateValues = {
            'On' : '1',
            'Off': '0'
        }

        if value in ValueStateValues:
            MuteCmdString = 'MUTE{:>4}\r'.format(ValueStateValues[value])
            self.__SetHelper('Mute', MuteCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetMute')

    def SetPower(self, value, qualifier):

        ValueStateValues = {
            'On' : '1',
            'Off': '0'
        }

        if value in ValueStateValues:
            PowerCmdString = 'POWR{:>4}\r'.format(ValueStateValues[value])
            self.__SetHelper('Power', PowerCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPower')

    def UpdatePower(self, value, qualifier):

        ValueStateValues = {
            1: 'On'
        }

        PowerCmdString = 'POWR   ?\r'
        print(PowerCmdString)
        res = self.__UpdateHelper('Power', PowerCmdString, value, qualifier)
        print("Power Update Res: {}".format(res))
        if res:
            try:
                value = ValueStateValues[int(res)]
                print("Update Power Value: {}".format(value))
                self.WriteStatus('Power', value, qualifier)
            except (KeyError, ValueError):
                self.Error(['Power: Invalid/unexpected response'])

    def UpdateSerialNumber(self, value, qualifier):

        SerialNumberCmdString = 'SRNO   ?\r'
        res = self.__UpdateHelper('SerialNumber', SerialNumberCmdString, value, qualifier)
        if res:
            try:
                value = str(res)
                if value is not None:
                    self.WriteStatus('SerialNumber', value, None)
            except ValueError:
                pass

    def SetVolume(self, value, qualifier):

        if 1 <= value <= 100:
            VolumeCmdString = 'VOLM{:>4}\r'.format(value)
            self.__SetHelper('Volume', VolumeCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetVolume')

    def UpdateVolume(self, value, qualifier):

        VolumeCmdString = 'VOLM   ?\r'
        res = self.__UpdateHelper('Volume', VolumeCmdString, value, qualifier)
        if res:
            try:
                value = int(res)
                if 0 <= value <= 100:
                    self.WriteStatus('Volume', value, qualifier)
            except ValueError:
                self.Error(['Volume: Invalid/unexpected response'])

    def __CheckResponseForErrors(self, sourceCmdName, response):
        print("Sharp Display Check Error Command: {}".format(sourceCmdName))
        print("Sharp Display Check Error Response: {}".format(response))
        if 'ERR' in response:
            self.Error(['{}: Error occurred.'.format(sourceCmdName)])
            response = ''
        elif 'WAIT' in response:
            self.Error([sourceCmdName + ' : Waiting for a response.'])
            response = ''
        return response

    def __SetHelper(self, command, commandstring, value, qualifier):

        self.Debug = True
        if self.Authenticated in ['Not Needed', 'Authenticated']:
            if self.Unidirectional == 'True':
                self.Send(commandstring)
            else:
                res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag='\r')
                print("Sharp Display Set Helper Res: {}".format(res))
                if not res:
                    self.Error(['{}: Invalid/unexpected response'.format(command)])
                else:
                    res = self.__CheckResponseForErrors(command, res.decode())

        else:
            self.Discard('Not Authenticated')

    def __UpdateHelper(self, command, commandstring, value, qualifier):

        if self.Authenticated in ['Not Needed', 'Authenticated']:
            if self.initializationChk:
                self.OnConnected()
                self.initializationChk = False

            self.counter = self.counter + 1
            if self.counter > self.connectionCounter and self.connectionFlag:
                self.OnDisconnected()

            if self.Unidirectional == 'True':
                self.Discard('Inappropriate Command ' + command)
                return ''
            else:
                res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag='\r')
                print("Sharp Display Update Helper Res: {}".format(res))
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
                self.Subscription[command] = {'method': {}}

            Subscribe = self.Subscription[command]
            Method = Subscribe['method']

            if qualifier:
                for Parameter in Command['Parameters']:
                    try:
                        Method = Method[qualifier[Parameter]]
                    except BaseException:
                        if Parameter in qualifier:
                            Method[qualifier[Parameter]] = {}
                            Method = Method[qualifier[Parameter]]
                        else:
                            return

            Method['callback'] = callback
            Method['qualifier'] = qualifier
        else:
            print("SubscribeStatus Error: {}{}{}".format(command, qualifier, callback))
            raise KeyError('Invalid command for SubscribeStatus ' + command)

    # This method is to check the command with new status have a callback method then trigger the callback
    def NewStatus(self, command, value, qualifier):
        if command in self.Subscription:
            Subscribe = self.Subscription[command]
            Method = Subscribe['method']
            Command = self.Commands[command]
            if qualifier:
                for Parameter in Command['Parameters']:
                    try:
                        Method = Method[qualifier[Parameter]]
                    except BaseException:
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
        except BaseException:
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
            except BaseException:
                return None
        else:
            raise KeyError('Invalid command for ReadStatus: ' + command)

    def __ReceiveData(self, interface, data):
        # Handle incoming data
        self.__receiveBuffer += data
        index = 0    # Start of possible good data

        # check incoming data if it matched any expected data from device module
        for regexString, CurrentMatch in self.__matchStringDict.items():
            while True:
                result = re.search(regexString, self.__receiveBuffer)
                if result:
                    index = result.start()
                    CurrentMatch['callback'](result, CurrentMatch['para'])
                    self.__receiveBuffer = self.__receiveBuffer[:result.start()] + self.__receiveBuffer[result.end():]
                else:
                    break

        if index:
            # Clear out any junk data that came in before any good matches.
            self.__receiveBuffer = self.__receiveBuffer[index:]
        else:
            # In rare cases, the buffer could be filled with garbage quickly.
            # Make sure the buffer is capped.  Max buffer size set in init.
            self.__receiveBuffer = self.__receiveBuffer[-self.__maxBufferSize:]

    # Add regular expression so that it can be check on incoming data from device.
    def AddMatchString(self, regex_string, callback, arg):
        print("Match String Called. Regex: {}, callback: {}, arg: {}".format(regex_string, callback, arg))
        if regex_string not in self.__matchStringDict:
            self.__matchStringDict[regex_string] = {'callback': callback, 'para': arg}

class DeviceEthernetClass:
    def __init__(self):

        self.Subscription = {}
        self.ReceiveData = self.__ReceiveData
        self.__receiveBuffer = b''
        self.__maxBufferSize = 2048
        self.__matchStringDict = {}
        self.Debug = False
        self.deviceUsername = None
        self.devicePassword = None
        self.Models = {}

        self.Commands = {
            'AspectRatio': { 'Status': {}, 'AllowedValues': ['Auto', 'Normal', 'Zoom', 'Dot by Dot', '4:3', '14:9', '16:9']},
            'ConnectionStatus': {'Status': {}},
            'Input': { 'Status': {}, 'AllowedValues': ['TV', 'Composite', 'HDMI 1', 'HDMI 2', 'HDMI 3', 'USB', 'Home']},
            'Mute': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Power': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Volume': { 'Status': {}},
        }

        self.AddMatchString(re.compile(b'Login:'), self.__MatchUsernamePrompt, None)
        self.AddMatchString(re.compile(b'Password:'), self.__MatchPasswordPrompt, None)

        self.login_regex = re.compile(b'(Password:|ERR\r)')

    def __MatchUsernamePrompt(self, match, tag):

        self.SetUsername( None, None)

    def __MatchPasswordPrompt(self, match, tag):

        self.SetPassword( None, None)

    def SetUsername(self, value, qualifier):

        if self.deviceUsername is not None:
            self.Send('{0}\r\n'.format(self.deviceUsername))
        else:
            self.MissingCredentialsLog('Username')

    def SetPassword(self, value, qualifier):

        if self.devicePassword is not None:
            self.Send('{0}\r\n'.format(self.devicePassword))
        else:
            self.MissingCredentialsLog('Password')

    def SetAspectRatio(self, value, qualifier):

        ValueStateValues = {
            'Auto'      : '1',
            'Normal'    : '2',
            'Zoom'      : '3',
            'Dot by Dot': '4',
            '4:3'       : '5',
            '14:9'      : '6',
            '16:9'      : '7'
        }

        if value in ValueStateValues:
            AspectRatioCmdString = 'WIDE{:>4}\r'.format(ValueStateValues[value])
            self.__SetHelper('AspectRatio', AspectRatioCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetAspectRatio')

    def SetInput(self, value, qualifier):

        ValueStateValues = {
            'TV'        : '0',
            'Composite' : '1',
            'HDMI 1'    : '2',
            'HDMI 2'    : '3',
            'HDMI 3'    : '4',
            'USB'       : '5',
            'Home'      : '6'
        }

        if value in ValueStateValues:
            InputCmdString = 'INPS{:>4}\r'.format(ValueStateValues[value])
            self.__SetHelper('Input', InputCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetInput')

    def SetMute(self, value, qualifier):

        ValueStateValues = {
            'On' : '1',
            'Off': '0'
        }

        if value in ValueStateValues:
            MuteCmdString = 'MUTE{:>4}\r'.format(ValueStateValues[value])
            self.__SetHelper('Mute', MuteCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetMute')

    def SetPower(self, value, qualifier):

        PowerCmdString = 'POWR   0\r'
        self.__SetHelper('Power', PowerCmdString, value, qualifier)

    def SetVolume(self, value, qualifier):

        if 1 <= value <= 100:
            VolumeCmdString = 'VOLM{:>4}\r'.format(value)
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

    def __ReceiveData(self, interface, data):
        # Handle incoming data
        self.__receiveBuffer += data
        index = 0    # Start of possible good data
        
        #check incoming data if it matched any expected data from device module
        for regexString, CurrentMatch in self.__matchStringDict.items():
            while True:
                result = re.search(regexString, self.__receiveBuffer)
                if result:
                    index = result.start()
                    CurrentMatch['callback'](result, CurrentMatch['para'])
                    self.__receiveBuffer = self.__receiveBuffer[:result.start()] + self.__receiveBuffer[result.end():]
                else:
                    break

        if index:
            # Clear out any junk data that came in before any good matches.
            self.__receiveBuffer = self.__receiveBuffer[index:]
        else:
            # In rare cases, the buffer could be filled with garbage quickly.
            # Make sure the buffer is capped.  Max buffer size set in init.
            self.__receiveBuffer = self.__receiveBuffer[-self.__maxBufferSize:]

    # Add regular expression so that it can be check on incoming data from device.
    def AddMatchString(self, regex_string, callback, arg):
        print("Match String Called. Regex: {}, callback: {}, arg: {}".format(regex_string, callback, arg))
        if regex_string not in self.__matchStringDict:
            self.__matchStringDict[regex_string] = {'callback': callback, 'para':arg}

    def MissingCredentialsLog(self, credential_type):
        if isinstance(self, EthernetClientInterface):
            port_info = 'IP Address: {0}:{1}'.format(self.IPAddress, self.IPPort)
        elif isinstance(self, SerialInterface):
            port_info = 'Host Alias: {0}\r\nPort: {1}'.format(self.Host.DeviceAlias, self.Port)
        else:
            return 
        ProgramLog("{0} module received a request from the device for a {1}, "
                   "but device{1} was not provided.\n Please provide a device{1} "
                   "and attempt again.\n Ex: dvInterface.device{1} = '{1}'\n Please "
                   "review the communication sheet.\n {2}"
                   .format(__name__, credential_type, port_info), 'warning')

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
