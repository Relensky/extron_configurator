from extronlib.interface import SerialInterface, EthernetClientInterface
import re

# --- Room Config Builder metadata (module level — read by the app, not by
# the driver). "device_type" controls which device-family tab offers these
# models; "models" marks this file as the DEFAULT module for those models
# in the app's Model dropdown; "connection" and "defaults" keys are
# config.json device properties applied to the device when a model is picked.
DEVICE_INFO = {
    "device_type": "doccam",
    "models": ["Ultra 8"],
    "connection": {
        "com_type": "Serial",
        "protocol": "",
        "host": "processor1",
        "serial_port": "",  # site-specific — blank
    },
    "defaults": {
        "btn_name": "",
        "lbl_name": "",
        "gve_id": "",
        "name": "Document Camera - Ultra 8",
        "device_id": None,
        "keep_alive_command": "Power",
        "keep_alive_interval": 10,
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


class DeviceClass:

    def __init__(self):

        self.Debug = False
        self.Models = {}

        self.Commands = {
            'AutoFocus': { 'Status': {}, 'AllowedValues': ['Lock', 'Enable']},
            'HDMIOutput': { 'Status': {}, 'AllowedValues': ['Original', '1280x720', '1920x1080']},
            'ImageRotation': { 'Status': {}, 'AllowedValues': ['Toggle', '0', '180']},
            'Pan': { 'Status': {}, 'AllowedValues': ['Up', 'Down']},
            'PanPosition': { 'Status': {}},
            'Power': { 'Status': {}, 'AllowedValues': ['On', 'Off']},
            'Tilt': { 'Status': {}, 'AllowedValues': ['Up', 'Down']},
            'TiltPosition': { 'Status': {}},
            'USBOutput': { 'Status': {}},
            'VGAOutput': { 'Status': {}, 'AllowedValues': ['Original', '640x480', '800x600', '1024x768']},
            'Zoom': { 'Status': {}, 'AllowedValues': ['In', 'Out']},
            'ZoomPosition': { 'Status': {}},
            }

    def SetAutoFocus(self, value, qualifier):

        ValueStateValues = {
            'Lock' : '\x02AFEN\x03', 
            'Enable' : '\x02AFLOCK\x03'
        }

        AutoFocusCmdString = ValueStateValues[value]
        self.__SetHelper('AutoFocus', AutoFocusCmdString, value, qualifier)

    def SetHDMIOutput(self, value, qualifier):

        ValueStateValues = {
            'Original' : '\x02HDMI\x03', 
            '1280x720' : '\x02HDMI1\x03', 
            '1920x1080' : '\x02HDMI2\x03'
        }

        HDMIOutputCmdString = ValueStateValues[value]
        self.__SetHelper('HDMIOutput', HDMIOutputCmdString, value, qualifier)

    def SetImageRotation(self, value, qualifier):

        ValueStateValues = {
            'Toggle' : '\x02ROT\x03', 
            '0' : '\x02ROT0\x03', 
            '180' : '\x02ROT1\x03'
        }

        ImageRotationCmdString = ValueStateValues[value]
        self.__SetHelper('ImageRotation', ImageRotationCmdString, value, qualifier)

    def SetPan(self, value, qualifier):

        ValueStateValues = {
            'Up' : '\x02PAN\x2B\x03', 
            'Down' : '\x02PAN\x2D\x03'
        }

        PanCmdString = ValueStateValues[value]
        self.__SetHelper('Pan', PanCmdString, value, qualifier)

    def SetPanPosition(self, value, qualifier):

        ValueConstraints = {
            'Min' : -100,
            'Max' : 100
            }

        if ValueConstraints['Min'] <= value <= ValueConstraints['Max']:
            PanPositionCmdString = '\x02PAN' + str(value) + '\x03'
            self.__SetHelper('PanPosition', PanPositionCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetPanPosition')

    def SetPower(self, value, qualifier):

        ValueStateValues = {
            'On' : '\x02PON\x03', 
            'Off' : '\x02POFF\x03'
        }

        PowerCmdString = ValueStateValues[value]
        self.__SetHelper('Power', PowerCmdString, value, qualifier)

    def SetTilt(self, value, qualifier):

        ValueStateValues = {
            'Up' : '\x02TILT\x2B\x03', 
            'Down' : '\x02TILT\x2D\x03'
        }

        TiltCmdString = ValueStateValues[value]
        self.__SetHelper('Tilt', TiltCmdString, value, qualifier)

    def SetTiltPosition(self, value, qualifier):

        ValueConstraints = {
            'Min' : -100,
            'Max' : 100
            }

        if ValueConstraints['Min'] <= value <= ValueConstraints['Max']:
            TiltPositionCmdString = '\x02TILT' + str(value) + '\x03'
            self.__SetHelper('TiltPosition', TiltPositionCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetTiltPosition')

    def SetUSBOutput(self, value, qualifier):

        USBOutputCmdString = '\x02USB\x03'
        self.__SetHelper('USBOutput', USBOutputCmdString, value, qualifier)

    def SetVGAOutput(self, value, qualifier):

        ValueStateValues = {
            'Original' : '\x02VGA\x03', 
            '640x480' : '\x02VGA1\x03', 
            '800x600' : '\x02VGA2\x03', 
            '1024x768' : '\x02VGA3\x03'
        }

        VGAOutputCmdString = ValueStateValues[value]
        self.__SetHelper('VGAOutput', VGAOutputCmdString, value, qualifier)

    def SetZoom(self, value, qualifier):

        ValueStateValues = {
            'In' : '\x02ZOOM\x2B\x03', 
            'Out' : '\x02ZOOM\x2D\x03'
        }

        ZoomCmdString = ValueStateValues[value]
        self.__SetHelper('Zoom', ZoomCmdString, value, qualifier)

    def SetZoomPosition(self, value, qualifier):

        ValueConstraints = {
            'Min' : 0,
            'Max' : 100
            }

        if ValueConstraints['Min'] <= value <= ValueConstraints['Max']:
            ZoomPositionCmdString = '\x02ZOOM' + str(value) + '\x03'
            self.__SetHelper('ZoomPosition', ZoomPositionCmdString, value, qualifier)
        else:
            self.Discard('Invalid Command for SetZoomPosition')

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