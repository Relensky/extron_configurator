import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'config_dictionary.dart';

class SystemSettingsView extends StatelessWidget {
  const SystemSettingsView({Key? key}) : super(key: key);

  // Define the standard dropdown options
  static const Map<String, List<String>> _standardDropdowns = {
    'gui_mic_mix': ['Yes', 'No', 'Ceiling'],
    'gui_routing_available': ['Yes', 'No'],
    'gui_routing_mode': ['Normal', 'Conference', 'Extended'],
    'gui_tab': ['2_Cam_Dev', '2_Mic_Dev', '3_Cam_Mic_Dev', '3_Cams_Dev', '4_Cams_Mic_Dev', 'Conference'],
    'gui_capture_source_available': ['Yes', 'No'],
    'gui_usb_or_vga': ['USB', 'VGA'],
  };

  // Define the combined options for Inputs & Tab Type
  static const Map<String, String> _sourceComboOptions = {
    "3_WL": "3 Sources: PC, HDMI, & Wireless",
    "4_DOC_USB": "4 Sources: PC, HDMI, Doc Cam, & USB",
    "4_DOC_VGA": "4 Sources: PC, HDMI, Doc Cam, & VGA",
    "4_DOC_WL": "4 Sources: PC, HDMI, Doc Cam, & Wireless",
    "4_DVD_USB": "4 Sources: PC, HDMI, DVD, & USB",
    "4_DVD_VGA": "4 Sources: PC, HDMI, DVD, & VGA",
    "5_BR_DOC_USB": "5 Sources: PC, HDMI, Doc Cam, BluRay, & USB",
    "5_BR_DOC_VGA": "5 Sources: PC, HDMI, Doc Cam, BluRay, & VGA",
    "5_DOC_DVD_USB": "5 Sources: PC, HDMI, Doc Cam, DVD, & USB",
    "5_DOC_DVD_VGA": "5 Sources: PC, HDMI, Doc Cam, DVD, & VGA",
    "5_DOC_USB_WL": "5 Sources: PC, HDMI, Doc Cam, USB, & Wireless",
    "5_DOC_VGA_WL": "5 Sources: PC, HDMI, Doc Cam, VGA, & Wireless",
    "6_BR_DOC_USB_WL": "6 Sources: PC, HDMI, BluRay, Doc Cam, USB, & Wireless",
    "6_BR_DOC_VGA_WL": "6 Sources: PC, HDMI, BluRay, Doc Cam, VGA, & Wireless",
    "6_DOC_DVD_USB_WL": "6 Sources: PC, HDMI, DVD, Doc Cam, USB, & Wireless",
    "6_DOC_DVD_VGA_WL": "6 Sources: PC, HDMI, DVD, Doc Cam, VGA, & Wireless"
  };

  Widget _wrapWithInfo(BuildContext context, String key, Widget field) {
    final desc = ConfigDictionary.descriptions[key];
    if (desc == null) return field;
    
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        IconButton(
          icon: const Icon(Icons.info_outline, color: Colors.blueAccent),
          tooltip: desc,
          onPressed: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(key),
                content: Text(desc),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
              )
            );
          },
        )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final systemSetup = provider.roomConfig['SYSTEM_SETUP'] as Map<String, dynamic>?;

    if (systemSetup == null || systemSetup.isEmpty) {
      return const Center(child: Text("No SYSTEM_SETUP found in the current config."));
    }

    // Used in widget keys so every row (and the title) is rebuilt fresh when
    // the theme flips; otherwise Flutter reuses keyless element slots and the
    // header/fields can render with stale styling after a light<->dark toggle.
    final theme = Theme.of(context);
    final brightness = theme.brightness;

    final List<String> configKeys = systemSetup.keys.where((k) => !k.startsWith('dev_')).toList();
    configKeys.sort();

    return ListView.builder(
      padding: const EdgeInsets.all(32.0),
      itemCount: configKeys.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            key: ValueKey('sys_settings_title_$brightness'),
            padding: const EdgeInsets.only(bottom: 20.0),
            child: Text(
              'System Settings',
              // Explicitly derive the color from the ACTIVE theme so the
              // header stays readable in both light and dark mode.
              style: theme.textTheme.headlineMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          );
        }

        final key = configKeys[index - 1];
        final value = systemSetup[key];

        // Hide gui_tab_type as it is handled by gui_inputs composite dropdown below
        if (key == 'gui_tab_type') return const SizedBox.shrink();

        Widget field;
        
        // 1. COMBINED GUI INPUTS & TAB TYPE DROPDOWN
        if (key == 'gui_inputs') {
          String inputs = systemSetup['gui_inputs']?.toString() ?? '';
          String tabType = systemSetup['gui_tab_type']?.toString() ?? '';
          String comboKey = '${inputs}_$tabType';

          field = DropdownButtonFormField<String>(
            value: _sourceComboOptions.containsKey(comboKey) ? comboKey : null,
            decoration: const InputDecoration(
              labelText: 'Sources & Routing Config (gui_inputs + gui_tab_type)', 
              border: OutlineInputBorder()
            ),
            items: _sourceComboOptions.entries.map((entry) {
              return DropdownMenuItem(value: entry.key, child: Text(entry.value));
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                int splitIdx = val.indexOf('_');
                if (splitIdx != -1) {
                  provider.updateDeviceValue('SYSTEM_SETUP', 'gui_inputs', val.substring(0, splitIdx));
                  provider.updateDeviceValue('SYSTEM_SETUP', 'gui_tab_type', val.substring(splitIdx + 1));
                }
              }
            }
          );
        } 
        
        // 2. STANDARD OVERRIDE DROPDOWNS
        else if (_standardDropdowns.containsKey(key)) {
          field = DropdownButtonFormField<String>(
            value: _standardDropdowns[key]!.contains(value?.toString()) ? value?.toString() : null,
            decoration: InputDecoration(labelText: key, border: const OutlineInputBorder()),
            items: _standardDropdowns[key]!.map((opt) {
              // Add a descriptive suffix for specific keys based on your request
              String displayText = opt;
              if (key == 'gui_mic_mix') {
                if (opt == 'Yes') displayText = 'Yes (Single Mic w/ Ducking)';
                if (opt == 'No') displayText = 'No (Single Mic w/ Mute)';
                if (opt == 'Ceiling') displayText = 'Ceiling (Voicelift & Mute)';
              }

              return DropdownMenuItem(value: opt, child: Text(displayText));
            }).toList(),
            onChanged: (val) {
              if (val != null) provider.updateDeviceValue('SYSTEM_SETUP', key, val);
            }
          );
        } 
        
        // 3. BOOLEAN SWITCHES
        else if (value is bool) {
          field = SwitchListTile(
            title: Text(key),
            value: value,
            onChanged: (val) => provider.updateDeviceValue('SYSTEM_SETUP', key, val),
          );
        } 
        
        // 4. STANDARD TEXT FIELDS (Fallback)
        else {
          field = TextFormField(
            initialValue: value?.toString() ?? '',
            decoration: InputDecoration(labelText: key, border: const OutlineInputBorder()),
            onChanged: (val) {
              dynamic parsedVal = val;
              if (value is int) parsedVal = int.tryParse(val) ?? 0;
              provider.updateDeviceValue('SYSTEM_SETUP', key, parsedVal);
            },
          );
        }

        return Padding(
          // Keyed on the config key AND brightness: guarantees a clean rebuild
          // of every row when the theme toggles, and prevents index-based slot
          // reuse from ever displaying a neighboring field's stale state.
          key: ValueKey('${key}_$brightness'),
          padding: const EdgeInsets.only(bottom: 16.0),
          child: _wrapWithInfo(context, key, field),
        );
      },
    );
  }
}