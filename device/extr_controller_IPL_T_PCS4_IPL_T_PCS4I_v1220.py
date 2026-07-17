from extronlib.interface import SerialInterface, EthernetClientInterface
from re import compile, search
from extronlib.system import Wait, ProgramLog

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "power",
    "models": ["IPL T PCS4", "IPL T PCS4i"],
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 23,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",  # site-specific — blank
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_Power1",
        "lbl_name": "Lbl_Pwr_Connection",
        "gve_id": "Power1",
        "name": "Power Controller - IPL T PCS4",
        "keep_alive_command": "ExecutiveMode",
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
        self._compile_list = {}
        self.Subscription = {}
        self.ReceiveData = self.__ReceiveData
        self._ReceiveBuffer = b''
        self.counter = 0
        self.connectionFlag = True
        self.initializationChk = True
        self.Debug = False
        self.Models = {}
        self.devicePassword = 'extron'

        self.Commands = {
            'ConnectionStatus': {'Status': {}},
            'ExecutiveMode': {'Status': {}},
            'OutputReferenceThreshold': {'Parameters': ['Output'], 'Status': {}},
            'PowerControl': {'Parameters': ['Output'], 'Status': {}},
        }

        self.VerboseDisabled = True
        self.PasswdPromptCount = 0
        self.Authenticated = 'Not Needed'

        if self.Unidirectional == 'False':
            self.AddMatchString(compile(b'Password:'), self.__MatchPassword, None)
            self.AddMatchString(compile(b'Login Administrator\r\n'), self.__MatchLoginAdmin, None)
            self.AddMatchString(compile(b'Login User\r\n'), self.__MatchLoginUser, None)
            self.AddMatchString(compile(b'Vrb3\r\n'), self.__MatchVerboseMode, None)

            self.AddMatchString(compile(b'Exe([0-1])\r\n'), self.__MatchExecutiveMode, None)
            self.AddMatchString(compile(b'([0-2]),([0-2]),([0-2]),([0-2])\r\n'), self.__MatchOutputReferenceThreshold, None)
            self.AddMatchString(compile(b'Cpn0([1-4]) Ppc([0-1])\r\n'), self.__MatchPowerControl, None)
            self.AddMatchString(compile(b'E([0-3][0-9])\r\n'), self.__MatchError, None)

    def __MatchPassword(self, match, tag):
        self.PasswdPromptCount += 1
                
        if self.devicePassword is not None:
            if self.PasswdPromptCount < 3:
                self.Send('{0}\r\n'.format(self.devicePassword))
        else:
            self.MissingCredentialsLog('Password')

        if self.PasswdPromptCount == 3:
            print('Log in failed. Please supply proper Admin password')
            self.Authenticated = 'None'

    def __MatchLoginAdmin(self, match, tag):

        self.Authenticated = 'Admin'
        self.PasswdPromptCount = 0
        self.Send('w3cv\r\n')

    def __MatchLoginUser(self, match, tag):

        self.Authenticated = 'User'
        self.PasswdPromptCount = 0
        print('Logged in as User. May have limited functionality.')
        self.Send('w3cv\r\n')


    def __MatchVerboseMode(self, match, qualifier):
        self.OnConnected()
        self.VerboseDisabled = False

    def SetExecutiveMode(self, value, qualifier):

        ExecutiveModeStateValues = {
            'Off': '0',
            'On': '1'
        }

        commandString = '{0}X\r\n'.format(ExecutiveModeStateValues[value])
        self.__SetHelper('ExecutiveMode', commandString, value, qualifier)

    def UpdateExecutiveMode(self, value, qualifier):

        if self.VerboseDisabled and self.Authenticated in ['Admin', 'User', 'Not Needed']:
            self.Send('w3cv\r\n')
        commandString = 'X\r\n'
        self.__UpdateHelper('ExecutiveMode', commandString, value, qualifier)

    def __MatchExecutiveMode(self, match, tag):

        ExecutiveModeStateNames = {
            '0': 'Off',
            '1': 'On'
        }

        value = ExecutiveModeStateNames[match.group(1).decode()]
        self.WriteStatus('ExecutiveMode', value, None)

    def SetOutputReferenceThreshold(self, value, qualifier):

        OutputReferenceThresholdStateValues = {
                    'Full': '2',
                    'Standby': '1',
                    'None': '0'
                    }
        OutputConstraints = {
                    'Min': 1,
                    'Max': 4
                    }

        outputPort = qualifier['Output']

        if OutputConstraints['Min'] <= int(outputPort) <= OutputConstraints['Max']:
            commandString = 'W{0}*{1}TH\r\n'.format(outputPort, OutputReferenceThresholdStateValues[value])
            self.__SetHelper('OutputReferenceThreshold', commandString, value, qualifier)
        else:
            print('Invalid Command')

    def UpdateOutputReferenceThreshold(self, value, qualifier):


        OutputReferenceThresholdCmdString = 'WTH\r\n'
        self.__UpdateHelper('OutputReferenceThreshold', OutputReferenceThresholdCmdString, value, qualifier)

    def __MatchOutputReferenceThreshold(self, match, tag):

        OutputReferenceThresholdState = {
           '0' : 'None',
           '1' : 'Standby',
           '2' : 'Full'
           }

        value1 = OutputReferenceThresholdState[match.group(1).decode()]
        self.WriteStatus('OutputReferenceThreshold', value1, {'Output': '1'})

        value2 = OutputReferenceThresholdState[match.group(2).decode()]
        self.WriteStatus('OutputReferenceThreshold', value2, {'Output': '2'})

        value3 = OutputReferenceThresholdState[match.group(3).decode()]
        self.WriteStatus('OutputReferenceThreshold', value3, {'Output': '3'})

        value4 = OutputReferenceThresholdState[match.group(4).decode()]
        self.WriteStatus('OutputReferenceThreshold', value4, {'Output': '4'})


    def SetPowerControl(self, value, qualifier):

        PowerControlStateValues = {
                    'Off': '0',
                    'On': '1'
                    }
        OutputConstraints = {
                    'Min': 1,
                    'Max': 4
                    }

        outputPort = qualifier['Output']

        if OutputConstraints['Min'] <= int(outputPort) <= OutputConstraints['Max']:
            PowerControlCmdString = 'W{0}*{1}PC\r\n'.format(outputPort, PowerControlStateValues[value])
            self.__SetHelper('PowerControl', PowerControlCmdString, value, qualifier)
        else:
            print('Invalid Command')

    def UpdatePowerControl(self, value, qualifier):

        OutputConstraints = {
                    'Min': 1,
                    'Max': 4
                    }

        outputPort = qualifier['Output']

        if OutputConstraints['Min'] <= int(outputPort) <= OutputConstraints['Max']:
            PowerControlCmdString = 'W{0}PC\r\n'.format(outputPort)
            self.__UpdateHelper('PowerControl', PowerControlCmdString, value, qualifier)
        else:
            print('Invalid Command')

    def __MatchPowerControl(self, match, tag):

        PowerControlStateNames = {
           '0': 'Off',
           '1': 'On'
          }

        value = PowerControlStateNames[match.group(2).decode()]
        qualifier = {'Output': match.group(1).decode()}

        self.WriteStatus('PowerControl', value, qualifier)

    def __SetHelper(self, command, commandstring, value, qualifier):
        self.Debug = True

        self.Send(commandstring)

    def __UpdateHelper(self, command, commandstring, value, qualifier):
            
        if self.Authenticated in ['User', 'Admin', 'Not Needed']:
            if self.Unidirectional == 'True':
                print('Inappropriate Command ', command)
            else:
                if self.initializationChk:
                    self.OnConnected()
                    self.initializationChk = False

                self.counter = self.counter + 1
                if self.counter > self.connectionCounter and self.connectionFlag:
                    self.OnDisconnected()

                if self.VerboseDisabled:
                    @Wait(1)
                    def SendVerbose():
                        self.Send('w3cv\r\n')
                        self.Send(commandstring)
                else:
                    self.Send(commandstring)

    def __MatchError(self, match, tag):

        DeviceErrorCodes = {
            '01': 'Invalid input number (too large)',
            '10': 'Invalid command',
            '11': 'Invalid preset number',
            '12': 'Invalid port number',
            '13': 'Invalid value',
            '14': 'Command not available for this configuration',
            '17': 'System timed out',
            '22': 'Busy',
            '23': 'Checksum error',
            '24': 'Privilege violation',
            '25': 'Device not present',
            '26': 'Maximum number of connections exceeded',
            '27': 'Invalid event number',
            '28': 'Bad filename or file not found',
        }
        value = match.group(1).decode('ascii')
        if value in DeviceErrorCodes:
            print(DeviceErrorCodes[match.group(1).decode('ascii')])
        else:
            print('Unrecognize error code: ' + match.group(0).decode('ascii'))

    def OnConnected(self):
        self.connectionFlag = True
        self.WriteStatus('ConnectionStatus', 'Connected')
        self.counter = 0

    def OnDisconnected(self):
        self.WriteStatus('ConnectionStatus', 'Disconnected')
        self.connectionFlag = False

        self.Authenticated = 'Not Needed'
        self.PasswdPromptCount = 0
        self.VerboseDisabled = True

    ######################################################
    # RECOMMENDED not to modify the code below this point
    ######################################################
    # Send Control Commands
    def Set(self, command, value, qualifier=None):
        method = 'Set%s' % command
        if hasattr(self, method) and callable(getattr(self, method)):
            getattr(self, method)(value, qualifier)
        else:
            print(command, 'does not support Set.')
    # Send Update Commands

    def Update(self, command, qualifier=None):
        method = 'Update%s' % command
        if hasattr(self, method) and callable(getattr(self, method)):
            getattr(self, method)(None, qualifier)
        else:
            print(command, 'does not support Update.')

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


    # This method is to tie an specific command with a parameter to a call back method
    # when its value is updated. It sets how often the command will be query, if the command
    # have the update method.
    # If the command doesn't have the update feature then that command is only used for feedback
    def SubscribeStatus(self, command, qualifier, callback):
        Command = self.Commands.get(command)
        if Command:
            if command not in self.Subscription:
                self.Subscription[command] = {'method': {}}

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
        if command in self.Subscription:
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
        # handling incoming unsolicited data
        self._ReceiveBuffer += data
        # check incoming data if it matched any expected data from device module
        if self.CheckMatchedString() and len(self._ReceiveBuffer) > 10000:
            self._ReceiveBuffer = b''

    # Add regular expression so that it can be check on incoming data from device.
    def AddMatchString(self, regex_string, callback, arg):
        if regex_string not in self._compile_list:
            self._compile_list[regex_string] = {'callback': callback, 'para': arg}

    # Check incoming unsolicited data to see if it was matched with device expectancy.
    def CheckMatchedString(self):
        for regexString in self._compile_list:
            while True:
                result = search(regexString, self._ReceiveBuffer)
                if result:
                    self._compile_list[regexString]['callback'](result, self._compile_list[regexString]['para'])
                    self._ReceiveBuffer = self._ReceiveBuffer.replace(result.group(0), b'')
                else:
                    break
        return True


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
