from extronlib.interface import SerialInterface, EthernetClientInterface
from extronlib.system import Wait, ProgramLog

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "display",
    "models": ["E758", "E868", "E988"],
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 7142,
        "service_port": 0,
        "host": "processor1",
        "ip_address": "",  # site-specific — blank
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "Btn_Con_Projector1",
        "lbl_name": "Lbl_Proj_Model_Proj1",
        "gve_id": "Proj1",
        "name": "Display - E758",
        "device_id": "1",
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
    "network": {
        "protocol": "TCP",
        "net_port": 7142,
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
        self._DeviceID = 0x41
        self.Models = {}

        self.Commands = {
            'ConnectionStatus': {'Status': {}},
            'AspectRatio': {'Status': {}, 'AllowedValues': ['Normal', 'Full', 'Zoom', '1:1']},
            'Input': {'Status': {}, 'AllowedValues': ['HDMI 1', 'HDMI 2', 'HDMI 3', 'VGA (RGB)', 'VGA (YPbPr)', 'AV', 'Media Player']},
            'MenuNavigation': {'Status': {}, 'AllowedValues': ['Up', 'Down', 'Left', 'Right', 'Ok', 'Menu', 'Exit']},
            'Power': {'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Volume': {'Status': {}},
        }
        self._cmd_queue = []     # list of (callable, post_wait_seconds)
        self._cmd_busy  = False  # true while a command is "in flight"
        self._default_gap = 0.05 # small gap between ordinary commands (after reply)

        # Commands that require a long "cool-down" AFTER reply
        self._post_wait_map = {
            'Power'        : 15,   # CTL power on/off
            'Input'        : 10,   # VCP-00-60
        }

    @property
    def DeviceID(self):
        return self._DeviceID

    @DeviceID.setter
    def DeviceID(self, value):
        if value == 'Broadcast':
            self._DeviceID = 0x2A
        elif 1 <= int(value) <= 100:
            self._DeviceID = 64 + int(value)
        else:
            print('Invalid Device ID parameter.')

    def keep_alive(self):

        command_string = b'\x010\x2A0A06\x0201D6\x03'
        checksum = self.__calculate_checksum(command_string)
        self.Send(command_string + checksum + b'\r')

    def __calculate_checksum(self, command_string):

        checksum = 0
        for byte in command_string[1:]:
            checksum ^= byte
        return bytes([checksum])

    def __build_setstring(self, op_code_page, op_code, value):

        header = b'\x010' + bytes([self._DeviceID]) + b'0E0A'
        message = b'\x02' + op_code_page + op_code + b'00' + value + b'\x03'
        checksum = self.__calculate_checksum(header + message)
        delimiter = b'\r'
        return header + message + checksum + delimiter

    def __build_getstring(self, op_code_page, op_code):

        header = b'\x010' + bytes([self._DeviceID]) + b'0C06'
        message = b'\x02' + op_code_page + op_code + b'\x03'
        checksum = self.__calculate_checksum(header + message)
        delimiter = b'\r'
        return header + message + checksum + delimiter
    
    def SetAspectRatio(self, value, qualifier):

        ValueStateValues = {
            'Normal' : b'01',
            'Full'   : b'02',
            'Zoom'   : b'04',
            '1:1'    : b'07'
        }

        if value in ValueStateValues:
            AspectRatioCmdString = self.__build_setstring(b'02', b'70', ValueStateValues[value])
            self.__SetHelper('AspectRatio', AspectRatioCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetAspectRatio')

    def UpdateAspectRatio(self, value, qualifier):

        AspectRatioCmdString = self.__build_getstring(b'02', b'70')
        res = self.__UpdateHelper('AspectRatio', AspectRatioCmdString, value, qualifier)
        if res:
            try:
                ValueStateValues = {
                    b'1' : 'Normal',
                    b'2' : 'Full',
                    b'4' : 'Zoom',
                    b'7' : '1:1'
                }

                value = ValueStateValues[res[23:24]]
                self.WriteStatus('AspectRatio', value, qualifier)
            except (KeyError, IndexError, AttributeError):
                self.Error(['Aspect Ratio: Invalid/unexpected response'])

    def SetInput(self, value, qualifier):
        ValueStateValues = {
            'HDMI 1'       : b'11',
            'HDMI 2'       : b'12',
            'HDMI 3'       : b'82',
            'VGA (RGB)'    : b'01',
            'VGA (YPbPr)'  : b'0C',
            'AV'           : b'05',
            'Media Player' : b'87',
        }
        if value in ValueStateValues:
            cmd = self.__build_setstring(b'00', b'60', ValueStateValues[value])
            # Queue it; scheduler will enforce the 10 s wait (post-wait for 'Input')
            self.__QueuedSet('Input', cmd, value, qualifier)
        else:
            self.Discard('Invalid Command for SetInput')


    def UpdateInput(self, value, qualifier):
        cmd = self.__build_getstring(b'00', b'60')
        def _parse(res):
            code16 = self.__extract_current_value_16bit(res)
            mapping = {
                b'0011': 'HDMI 1',
                b'0012': 'HDMI 2',
                b'0082': 'HDMI 3',
                b'0001': 'VGA (RGB)',
                b'000C': 'VGA (YPbPr)',
                b'0005': 'AV',
                b'0087': 'Media Player',
            }
            try:
                self.WriteStatus('Input', mapping[code16], qualifier)
            except KeyError:
                self.Error(['Input: Invalid/unexpected response'])
        self.__QueuedUpdate('Input', cmd, _parse)


    def SetMenuNavigation(self, value, qualifier):

        ValueStateValues = {
            'Up'    : b'15',
            'Down'  : b'14',
            'Left'  : b'21',
            'Right' : b'22',
            'Ok'    : b'23',
            'Menu'  : b'20',
            'Exit'  : b'1F'
        }

        if value in ValueStateValues:
            temp = b''.join([b'\x010', bytes([self.DeviceID]), b'0A0C\x02C21000', ValueStateValues[value], b'01\x03'])
            MenuNavigationCmdString = b''.join([temp, self.__calculate_checksum(temp), b'\r'])
            self.__SetHelper('MenuNavigation', MenuNavigationCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetMenuNavigation')

    def SetPower(self, value, qualifier):
        ValueStateValues = { 'On': b'1', 'Off': b'4' }
        if value in ValueStateValues:
            temp = b''.join([b'\x010', bytes([self._DeviceID]), b'0A0C\x02C203D6000', ValueStateValues[value], b'\x03'])
            cmd = b''.join([temp, self.__calculate_checksum(temp), b'\r'])
            self.__QueuedSet('Power', cmd, value, qualifier)  # 15 s enforced by scheduler
        else:
            self.Discard('Invalid Command for SetPower')


    def UpdatePower(self, value, qualifier):
        temp = b''.join([b'\x010', bytes([self._DeviceID]), b'0A06\x0201D6\x03'])
        cmd = b''.join([temp, self.__calculate_checksum(temp), b'\r'])

        def _parse(res):
            # CTL-01D6 reply: last 4 chars in the message block are Current power mode.
            mode = self.__extract_message(res)[-4:]  # b'0001', b'0002', b'0004', etc.
            mapping = {
                b'0001': 'On',
                b'0002': 'Standby (Power Save)',
                b'0003': 'Reserved',
                b'0004': 'Off',
            }
            try:
                self.WriteStatus('Power', mapping[mode], qualifier)
            except KeyError:
                self.Error(['Power: Invalid/unexpected response'])

        self.__QueuedUpdate('Power', cmd, _parse)


    def SetVolume(self, value, qualifier):

        if 0 <= value <= 100:
            hexVol = hex(value).split('x')[-1].zfill(2)
            VolumeCmdString = self.__build_setstring(b'00', b'62', hexVol.encode())
            self.__SetHelper('Volume', VolumeCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetVolume')

    def __CheckResponseForErrors(self, sourceCmdName, response):
        #msg = ("NEC {} Cmd: {} Reponse: {}".format(self._DeviceID, sourceCmdName, response))
        #ProgramLog(msg, "info")
        if response and response[8:10].decode() == '01':
            self.Error(['{0}: An error occurred.'.format(sourceCmdName)])
            response = ''
        return response

    def __SetHelper(self, command, commandstring, value, qualifier):
        #msg = ("NEC {} Set Helper CMD: {} CMDSTRING: {}".format(self._DeviceID, command, commandstring))
        #ProgramLog(msg, "info") 
        self.Debug = True

        if self.Unidirectional == 'True' or self._DeviceID == 0x2A:
            self.Send(commandstring)
        else:
            res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag=b'\r')
            if not res:
                self.Error(['{}: Invalid/unexpected response'.format(command)])
            else:
                res = self.__CheckResponseForErrors(command, res)

    def __UpdateHelper(self, command, commandstring, value, qualifier):
        #msg = ("NEC {} Update Helper CMD: {} CMDSTRING: {}".format(self._DeviceID, command, commandstring))
        #ProgramLog(msg, "info")
        if self.Unidirectional == 'True' or self._DeviceID == 0x2A:
            self.Discard('Inappropriate Command ' + command)
            return ''
        else:
            if self.initializationChk:
                self.OnConnected()
                self.initializationChk = False

            self.counter = self.counter + 1
            if self.counter > self.connectionCounter and self.connectionFlag:
                self.OnDisconnected()

            res = self.SendAndWait(commandstring, self.DefaultResponseTimeout, deliTag=b'\r')
            if not res:
                return ''
            else:
                return self.__CheckResponseForErrors(command, res)


    # ---- queue mechanics -----------------------------------------------------
    def __queue(self, fn, post_wait=0):
        """Enqueue a callable that sends exactly one command and returns
        only AFTER SendAndWait (i.e., after the monitor's reply)."""
        self._cmd_queue.append((fn, post_wait))
        self.__process_cmd_queue()

    def __process_cmd_queue(self):
        if self._cmd_busy or not self._cmd_queue:
            return
        self._cmd_busy = True
        fn, post_wait = self._cmd_queue.pop(0)

        # Run the task (it blocks until SendAndWait returns or times out).
        fn()

        # After the reply, enforce the mandatory cool-down (or a tiny gap).
        gap = max(post_wait, self._default_gap)
        Wait(gap, self.___queue_release)

    def ___queue_release(self):
        self._cmd_busy = False
        self.__process_cmd_queue()

    # ---- tiny wrappers so Set*/Update* can "just enqueue" --------------------
    def __QueuedSet(self, command_name, cmd_bytes, value, qualifier):
        """Send a Set command and apply post-wait if required by the manual."""
        post_wait = self._post_wait_map.get(command_name, 0)
        def _task():
            self.__SetHelper(command_name, cmd_bytes, value, qualifier)
        self.__queue(_task, post_wait=post_wait)

    def __QueuedUpdate(self, command_name, cmd_bytes, parser_fn):
        """Send a Get/Status command and parse the reply in parser_fn(res)."""
        def _task():
            res = self.__UpdateHelper(command_name, cmd_bytes, None, None)
            if res:
                try:
                    parser_fn(res)
                except Exception:
                    self.Error([f'{command_name}: Invalid/unexpected response'])
        self.__queue(_task, post_wait=0)

    # ---- message parsing helpers (defensive, format per §4.2.1~4.2.4) --------
    def __extract_message(self, response_bytes):
        """Return the Message block (bytes between STX and ETX)."""
        try:
            s = response_bytes.index(b'\x02') + 1
            e = response_bytes.index(b'\x03', s)
            return response_bytes[s:e]
        except ValueError:
            return b''

    def __extract_current_value_16bit(self, response_bytes):
        """For VCP Get reply: take the last 4 ASCII-hex chars as the 16-bit Current Value."""
        msg = self.__extract_message(response_bytes)
        return msg[-4:] if len(msg) >= 4 else b''


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
        