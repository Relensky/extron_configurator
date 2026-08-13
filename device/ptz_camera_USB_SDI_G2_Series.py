from extronlib.interface import SerialInterface, EthernetClientInterface
from struct import pack
import re
# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "camera",
    "models": ["12X-USB-G2", "20X-SDI-G2", "20X-USB-G2", "12X-SDI-G2"],
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 5678,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",  # site-specific — blank
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_Cam1",
        "lbl_name": "Lbl_InstCam_Model",
        "gve_id": "Cam1",
        "name": "Camera - 12X-USB-G2",
        "device_id": None,
        "keep_alive_command": "Power",
        "keep_alive_interval": 10,
        "keep_alive_trigger": None,
        "manual_disconnect": False,
        "user": "admin",
        "password": "ATEC2008",
    },
    # How this driver is reached on each connection style, read by the app:
    # changing com_type loads the matching block, and picking a model merges it
    # over "connection" + "defaults". Ports are the ones the module's
    # communication sheet documents; protocol, baud and service port are the
    # defaults declared by the wrapper classes at the bottom of this file.
    "network": {
        "protocol": "TCP",
        "net_port": 5678,
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

        self.WarmUpTime = 10.0
        self.CoolDownTime = 10.0
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


        self.Commands = {
            'ConnectionStatus': {'Status': {}},
            'AutoFocus': {'Parameters': ['Device ID'], 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'BackLight': {'Parameters': ['Device ID'], 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Focus': {'Parameters': ['Device ID', 'Focus Speed'], 'Status': {}, 'AllowedValues': ['Stop', 'Far', 'Near']},
            'Gain': {'Parameters': ['Device ID'], 'Status': {}, 'AllowedValues': ['Up', 'Down', 'Reset']},
            'Iris': {'Parameters': ['Device ID'], 'Status': {}, 'AllowedValues': ['Reset', 'Up', 'Down']},
            'PanTilt': {'Parameters': ['Device ID', 'Pan Speed', 'Tilt Speed'], 'Status': {}, 'AllowedValues': ['Up', 'Down', 'Left', 'Right', 'Up Left', 'Up Right', 'Down Left', 'Down Right', 'Stop', 'Home', 'Reset']},
            'Power': {'Parameters': ['Device ID'], 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'PresetRecall': {'Parameters': ['Device ID'], 'Status': {}},
            'PresetReset': {'Parameters': ['Device ID'], 'Status': {}},
            'PresetSave': {'Parameters': ['Device ID'], 'Status': {}},
            'Zoom': {'Parameters': ['Device ID', 'Zoom Speed'], 'Status': {}, 'AllowedValues': ['Stop', 'Tele', 'Wide']},
        }                    

        if self.Unidirectional == 'False':
            self.AddMatchString(re.compile(b'[\x00-\xFF]{2}(\x02|\x03|\x04|\x05|\x41)\xFF'), self.__MatchError, None)

        self.DeviceIDStates = {
            '1': b'\x81',
            '2': b'\x82',
            '3': b'\x83',
            '4': b'\x84',
            '5': b'\x85',
            '6': b'\x86',
            '7': b'\x87',
            'Broadcast': b'\x88'
        }

        self.MatchDeviceID = {
            b'\x90': '1',
            b'\xA0': '2',
            b'\xB0': '3',
            b'\xC0': '4',
            b'\xD0': '5',
            b'\xE0': '6',
            b'\xF0': '7',
            b'\x00': 'Broadcast'
        }
        
    def SetAutoFocus(self, value, qualifier):
        ValueStateValues = {
            'On'  : b'\x02', 
            'Off' : b'\x03'
        }

        AutoFocusCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x38', ValueStateValues[value], b'\xFF'])
        self.__SetHelper('AutoFocus', AutoFocusCmdString, value, qualifier)

    def UpdateAutoFocus(self, value, qualifier):

        ValueStateValues = {
            b'\x02' : 'On', 
            b'\x03' : 'Off'
        }

        AutoFocusCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x09\x04\x38\xFF'])
        res = self.__UpdateHelper('AutoFocus', AutoFocusCmdString, value, qualifier)
        if res:
            try:
                qualifier = {'Device ID' : self.MatchDeviceID[res[0:1]]}
                value = ValueStateValues[res[2:3]]
                self.WriteStatus('AutoFocus', value, qualifier)
            except (KeyError, IndexError):
                self.Error(['Auto Focus: Invalid/unexpected response'])
                
    def SetBackLight(self, value, qualifier):

        ValueStateValues = {
            'On'  : b'\x02', 
            'Off' : b'\x03'
        }

        BackLightCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x33', ValueStateValues[value], b'\xFF'])
        self.__SetHelper('BackLight', BackLightCmdString, value, qualifier)

    def UpdateBackLight(self, value, qualifier):

        ValueStateValues = {
            b'\x02' : 'On', 
            b'\x03' : 'Off'
        }

        BackLightCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x09\x04\x33\xFF'])
        res = self.__UpdateHelper('BackLight', BackLightCmdString, value, qualifier)
        if res:
            try:
                qualifier = {'Device ID': self.MatchDeviceID[res[0:1]]}
                value = ValueStateValues[res[2:3]]
                self.WriteStatus('BackLight', value, qualifier)
            except (KeyError, IndexError):
                self.Error(['Back Light: Invalid/unexpected response'])

    def SetFocus(self, value, qualifier):

        ValueStateValues = {
            'Stop' : 0x00,
            'Far'  : 0x20,
            'Near' : 0x30
        }

        if 0 <= int(qualifier['Focus Speed']) <= 7:
            if value == 'Stop':
                focusSpeed = b'\x00'
            else:
                focusSpeed = pack('>B', ValueStateValues[value] + int(qualifier['Focus Speed']))

            FocusCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x08', focusSpeed, b'\xFF'])
            self.__SetHelper('Focus', FocusCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetFocus')




    def SetGain(self, value, qualifier):

        ValueStateValues = {
            'Up'    : b'\x02', 
            'Down'  : b'\x03', 
            'Reset' : b'\x00'
        }

        GainCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x0C', ValueStateValues[value], b'\xFF'])
        self.__SetHelper('Gain', GainCmdString, value, qualifier)




    def SetIris(self, value, qualifier):

        ValueStateValues = {
            'Reset' : b'\x00', 
            'Up'    : b'\x02', 
            'Down'  : b'\x03'
        }

        IrisCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x0B', ValueStateValues[value], b'\xFF'])
        self.__SetHelper('Iris', IrisCmdString, value, qualifier)




    def SetPanTilt(self, value, qualifier):

        ValueStateValues = {
            'Up'         : b'\x03\x01',
            'Down'       : b'\x03\x02', 
            'Left'       : b'\x01\x03', 
            'Right'      : b'\x02\x03', 
            'Up Left'    : b'\x01\x01', 
            'Up Right'   : b'\x02\x01', 
            'Down Left'  : b'\x01\x02', 
            'Down Right' : b'\x02\x02', 
            'Stop'       : b'\x03\x03', 
            'Home'       : b'\x04', 
            'Reset'      : b'\x05'
        }

        if 1 <= int(qualifier['Pan Speed']) <= 24 and 1 <= int(qualifier['Tilt Speed']) <= 20:
            if value == 'Home' or value == 'Reset':
                PanTiltCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x06', ValueStateValues[value], b'\xFF'])
            else:
                speedByte = pack('>BB', int(qualifier['Pan Speed']), int(qualifier['Tilt Speed']))
                PanTiltCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x06\x01', speedByte, ValueStateValues[value], b'\xFF'])

            self.__SetHelper('PanTilt', PanTiltCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPanTilt')    

    def SetPower(self, value, qualifier):

        ValueStateValues = {
            'On'  : b'\x02',
            'Off' : b'\x03'
        }
        PowerCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x00', ValueStateValues[value], b'\xFF'])
        self.__SetHelper('Power', PowerCmdString, value, qualifier)

    def UpdatePower(self, value, qualifier):

        ValueStateValues = {
            b'\x02' : 'On', 
            b'\x03' : 'Off'
        }
        PowerCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x09\x04\x00\xFF'])
        res = self.__UpdateHelper('Power', PowerCmdString, value, qualifier)
        if res:
            if res[2:3] == b'\x04':
                self.Error(['Internal power circuit error.'])
            else:
                try:
                    qualifier = {'Device ID': self.MatchDeviceID[res[0:1]]}
                    value = ValueStateValues[res[2:3]]
                    self.WriteStatus('Power', value, qualifier)
                except (KeyError, IndexError):
                    self.Error(['Power: Invalid/unexpected response'])

    def SetPresetRecall(self, value, qualifier):

        if 0 <= int(value) <= 254:
            presetByte = pack('>B', int(value))
            PresetRecallCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x3F\x02', presetByte, b'\xFF'])

            self.__SetHelper('PresetRecall', PresetRecallCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPresetRecall')

    def SetPresetReset(self, value, qualifier):

        if 0 <= int(value) <= 254:
            presetByte = pack('>B', int(value))
            PresetResetCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x3F\x00', presetByte, b'\xFF'])

            self.__SetHelper('PresetReset', PresetResetCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPresetReset')

    def SetPresetSave(self, value, qualifier):

        if 0 <= int(value) <= 254:
            presetByte = pack('>B', int(value))
            PresetSaveCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x3F\x01', presetByte, b'\xFF'])

            self.__SetHelper('PresetSave', PresetSaveCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPresetSave')

    def SetZoom(self, value, qualifier):

        ValueStateValues = {
            'Stop' : 0x00, 
            'Tele' : 0x20, 
            'Wide' : 0x30
        }

        if 0 <= int(qualifier['Zoom Speed']) <= 7:
            if value == 'Stop':
                zoomSpeed = b'\x00'
            else:
                zoomSpeed = pack('>B', int(qualifier['Zoom Speed']) + ValueStateValues[value])

            ZoomCmdString = b''.join([self.DeviceIDStates[qualifier['Device ID']], b'\x01\x04\x07', zoomSpeed, b'\xFF'])
            self.__SetHelper('Zoom', ZoomCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetZoom')

    def __CheckResponseForErrors(self, sourceCmdName, response):

        DEVICE_ERROR_CODES = {
            b'\x02' : 'Syntax Error.',
            b'\x03' : 'Command Buffer Full.',
            b'\x04' : 'Command Canceled.',
            b'\x05' : 'No Socket.',
            b'\x41' : 'Command Not Executable.'
        }   
        if response[1:2] != b'\x50':
            if len(response) == 4:
                self.Error([DEVICE_ERROR_CODES[response[2:3]]])
                response = ''
        return response

    def __MatchError(self, match, tag):

        DEVICE_ERROR_CODES = {
            b'\x02' : 'Syntax Error.',
            b'\x03' : 'Command Buffer Full.',
            b'\x04' : 'Command Canceled.',
            b'\x05' : 'No Socket.',
            b'\x41' : 'Command Not Executable.'
        }   
        if match.group(1) in DEVICE_ERROR_CODES:
            self.Error([DEVICE_ERROR_CODES[match.group(1)]])

    def __SetHelper(self, command, commandstring, value, qualifier):
        self.Debug = True
        self.Send(commandstring)

    def __UpdateHelper(self, command, commandstring, value, qualifier):

        if self.Unidirectional == 'True' or self.DeviceIDStates[qualifier['Device ID']] == b'\x88':
            self.Discard('Inappropriate Command ' + command)
            return ''
        elif qualifier and qualifier['Device ID'] == 'Broadcast':
            self.Discard('Inappropriate Command ' + command)
            return ''
        else:
            if self.initializationChk:
                self.OnConnected()
                self.initializationChk = False

            self.counter = self.counter + 1
            if self.counter > self.connectionCounter and self.connectionFlag:
                self.OnDisconnected()

            res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag = b'\xFF')
            if res:
                return self.__CheckResponseForErrors(command, res)            

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

class DeviceEthernetClass:


    
    def __init__(self):

        self.Debug = False
        self.Models = {}
        self.cameraID = b'\x01'

        self.Commands = {
            'ConnectionStatus': {'Status': {}},
            'AutoFocus': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Focus': {'Parameters':['Focus Speed'], 'Status': {}, 'AllowedValues': ['Stop', 'Far', 'Near']},
            'PanTilt': {'Parameters':['Pan Speed','Tilt Speed'], 'Status': {}, 'AllowedValues': ['Up', 'Down', 'Left', 'Right', 'Up Left', 'Up Right', 'Down Left', 'Down Right', 'Stop', 'Home', 'Reset']},
            'PresetRecall': { 'Status': {}},
            'PresetReset': { 'Status': {}},
            'PresetSave': { 'Status': {}},
            'Zoom': {'Parameters':['Zoom Speed'], 'Status': {}, 'AllowedValues': ['Stop', 'Tele', 'Wide']},
        }

    @property
    def DeviceID(self):
        return self.cameraID

    @DeviceID.setter
    def DeviceID(self, value):
        if value == 'Broadcast':
            self.cameraID = b'\x88'
        elif 1 <= int(value) <= 7:
            self.cameraID = pack('>B', 0x80 + int(value)) 

    def SetAutoFocus(self, value, qualifier):

        ValueStateValues = {
            'On'  : b'\x02', 
            'Off' : b'\x03'
        }

        AutoFocusCmdString = b''.join([self.cameraID, b'\x01\x04\x38', ValueStateValues[value], b'\xFF'])
        self.__SetHelper('AutoFocus', AutoFocusCmdString, value, qualifier)

    def SetFocus(self, value, qualifier):

        ValueStateValues = {
            'Stop' : 0x00,
            'Far'  : 0x20,
            'Near' : 0x30
        }

        if 0 <= int(qualifier['Focus Speed']) <= 7:
            if value == 'Stop':
                focusSpeed = b'\x00'
            else:
                focusSpeed = pack('>B', ValueStateValues[value] + int(qualifier['Focus Speed']))

            FocusCmdString = b''.join([self.cameraID, b'\x01\x04\x08', focusSpeed, b'\xFF'])
            self.__SetHelper('Focus', FocusCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetFocus')

    def SetPanTilt(self, value, qualifier):

        ValueStateValues = {
            'Up'         : b'\x03\x01',
            'Down'       : b'\x03\x02', 
            'Left'       : b'\x01\x03', 
            'Right'      : b'\x02\x03', 
            'Up Left'    : b'\x01\x01', 
            'Up Right'   : b'\x02\x01', 
            'Down Left'  : b'\x01\x02', 
            'Down Right' : b'\x02\x02', 
            'Stop'       : b'\x03\x03', 
            'Home'       : b'\x04', 
            'Reset'      : b'\x05'
        }

        if 1 <= int(qualifier['Pan Speed']) <= 24 and 1 <= int(qualifier['Tilt Speed']) <= 20:
            if value == 'Home' or value == 'Reset':
                PanTiltCmdString = b''.join([self.cameraID, b'\x01\x06', ValueStateValues[value], b'\xFF'])
            else:
                speedByte = pack('>BB', int(qualifier['Pan Speed']), int(qualifier['Tilt Speed']))
                PanTiltCmdString = b''.join([self.cameraID, b'\x01\x06\x01', speedByte, ValueStateValues[value], b'\xFF'])

            self.__SetHelper('PanTilt', PanTiltCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPanTilt')

    def SetPresetRecall(self, value, qualifier):

        if 0 <= int(value) <= 254:
            presetByte = pack('>B', int(value))
            PresetRecallCmdString = b''.join([self.cameraID, b'\x01\x04\x3F\x02', presetByte, b'\xFF'])

            self.__SetHelper('PresetRecall', PresetRecallCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPresetRecall')

    def SetPresetReset(self, value, qualifier):

        if 0 <= int(value) <= 254:
            presetByte = pack('>B', int(value))
            PresetResetCmdString = b''.join([self.cameraID, b'\x01\x04\x3F\x00', presetByte, b'\xFF'])

            self.__SetHelper('PresetReset', PresetResetCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPresetReset')

    def SetPresetSave(self, value, qualifier):

        if 0 <= int(value) <= 254:
            presetByte = pack('>B', int(value))
            PresetSaveCmdString = b''.join([self.cameraID, b'\x01\x04\x3F\x01', presetByte, b'\xFF'])

            self.__SetHelper('PresetSave', PresetSaveCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPresetSave')

    def SetZoom(self, value, qualifier):

        ValueStateValues = {
            'Stop' : 0x00, 
            'Tele' : 0x20, 
            'Wide' : 0x30
        }

        if 0 <= int(qualifier['Zoom Speed']) <= 7:
            if value == 'Stop':
                zoomSpeed = b'\x00'
            else:
                zoomSpeed = pack('>B', int(qualifier['Zoom Speed']) + ValueStateValues[value])

            ZoomCmdString = b''.join([self.cameraID, b'\x01\x04\x07', zoomSpeed, b'\xFF'])
            self.__SetHelper('Zoom', ZoomCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetZoom')

    def __CheckResponseForErrors(self, sourceCmdName, response):

        return response

    def __SetHelper(self, command, commandstring, value, qualifier):
        self.Debug = True
        self.Send(commandstring)
    
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
        #print('Module: {}'.format(__name__), portInfo, 'Error Message: {}'.format(message[0]), sep='\r\n')
  
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

class EthernetClass(EthernetClientInterface, DeviceEthernetClass):

    def __init__(self, Hostname, IPPort, Protocol='TCP', ServicePort=0, Model=None):
        EthernetClientInterface.__init__(self, Hostname, IPPort, Protocol, ServicePort)
        self.ConnectionType = 'Ethernet'
        DeviceEthernetClass.__init__(self) 
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