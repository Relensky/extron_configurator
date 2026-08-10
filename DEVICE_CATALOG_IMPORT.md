# Device catalog import report

Imported **990 models** from the Extron engineering drawing
stencils in `drawings_library/` into `av_devices.json`.

## By product family

| Family | Models |
|---|---|
| Control Systems | 165 |
| Audio | 156 |
| DTP Systems | 132 |
| Fox Systems | 89 |
| XTP Systems | 65 |
| Scalers Switchers | 61 |
| Streaming | 58 |
| Architectural | 56 |
| Cables | 50 |
| Collaboration Systems | 35 |
| Matrix | 30 |
| Videowall Processors | 28 |
| USB | 23 |
| Room Scheduling | 16 |
| DA | 14 |
| Misc | 12 |

## What the drawings do not carry

The stencils are logical block diagrams. They give the model, part
number, description and connector set — and nothing about size, power or
price. Those four are left at 0 ("not recorded") rather than guessed, and
every report counts what is still blank instead of totalling it as zero:

- **Rack units** — recorded for 8 models the app already knew; blank for the rest.
- **Power draw (W)** and **heat (BTU/hr)** — blank for all of them.
- **Unit price** — blank for all of them.

- **195 models have no signal connectors** in their drawing:
  speakers, cables, mounting plates and blanks, which is correct, plus a
  few whose drawing the reader could not pair up. They can still be
  priced and counted; they just cannot be cabled until connectors are
  added.
- **12 models have no part number** in the stencil.

## Missing a Python control module

**932 of the 990 imported models have no Python
driver** in `device/`; 58 do. That is expected rather
than broken — most of the catalog is passive gear, cable and
architectural product that was never going to have a driver — but it is
the list to check before commissioning, because every entry on it is a
box the processor cannot touch.

This is deliberately NOT written into `av_devices.json`. Which models
have a driver changes every time a module is added to the library, and a
copy in the catalog would be wrong the first time that happened. The app
resolves it live instead:

- the **Pack List** carries a `Control module` column, naming the module
  or saying `none`;
- a **Devices Without a Control Module** section lists the room's
  undriven devices, and drops out entirely when there are none.

Models that DO have a driver:

- `DMP 128 Plus` — extr_dsp_DMP_128_Plus_Series.py
- `DMP 128 Plus AT` — extr_dsp_DMP_128_Plus_Series.py
- `DMP 128 Plus C` — extr_dsp_DMP_128_Plus_Series.py
- `DMP 128 Plus C AT` — extr_dsp_DMP_128_Plus_Series.py
- `DMP 128 Plus C V` — extr_dsp_DMP_128_Plus_Series.py
- `DMP 128 Plus C V AT` — extr_dsp_DMP_128_Plus_Series.py
- `DMP 64` — extr_dsp_DMP64_v1_2_0_0.py
- `DMP 64 Plus C` — extr_dsp_DMP_64_Plus_Series.py
- `DMP 64 Plus C AT` — extr_dsp_DMP_64_Plus_Series.py
- `DMP 64 Plus C V` — extr_dsp_DMP_64_Plus_Series.py
- `DMP 64 Plus C V AT` — extr_dsp_DMP_64_Plus_Series.py
- `DTP CrossPoint 108 4K` — extr_matrix_DTPCrossPoint_86_1084K.py
- `DTP CrossPoint 108 4K IPCP MA 70` — extr_matrix_DTPCrossPoint_86_1084K.py
- `DTP CrossPoint 108 4K IPCP SA` — extr_matrix_DTPCrossPoint_86_1084K.py
- `DTP CrossPoint 82 4K` — extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py
- `DTP CrossPoint 82 4K IPCP MA 70` — extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py
- `DTP CrossPoint 82 4K IPCP SA` — extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py
- `DTP CrossPoint 84` — extr_matrix_DTPCrossPoint84_v1_5_6_0.py
- `DTP CrossPoint 84 4K` — extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py
- `DTP CrossPoint 84 4K IPCP MA 70` — extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py
- `DTP CrossPoint 84 4K IPCP SA` — extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py
- `DTP CrossPoint 84 IPCP SA` — extr_matrix_DTPCrossPoint84_v1_5_6_0.py
- `DTP CrossPoint 86 4K` — extr_matrix_DTPCrossPoint_86_1084K.py
- `DTP CrossPoint 86 4K IPCP MA 70` — extr_matrix_DTPCrossPoint_86_1084K.py
- `DTP CrossPoint 86 4K IPCP SA` — extr_matrix_DTPCrossPoint_86_1084K.py
- `DTP HD DA4 4K 230` — extr_other_DTP_HD_DA4_4K_Series_v1_2_0_0.py
- `DTP HD DA4 4K 330` — extr_other_DTP_HD_DA4_4K_Series_v1_2_0_0.py
- `DTP HD DA8 4K 230` — extr_other_DTP_HD_DA4_4K_Series_v1_2_0_0.py
- `DTP HD DA8 4K 330` — extr_other_DTP_HD_DA4_4K_Series_v1_2_0_0.py
- `DTP2 CrossPoint 82` — extr_matrix_DTP2CrossPoint_82_v1_1_0_0.py
- `DTP2 CrossPoint 82 IPCP MA 70` — extr_matrix_DTP2CrossPoint_82_v1_1_0_0.py
- `DTP2 CrossPoint 82 IPCP SA` — extr_matrix_DTP2CrossPoint_82_v1_1_0_0.py
- `DTP3 IN2004 DI/DO` — extr_scaler_IN2004_Series_v1_0_3_0.py
- `DTP3 IN2004 DO` — extr_scaler_IN2004_Series_v1_0_3_0.py
- `IN1606` — extr_scaler_IN1606_IN1608_Series_v1_7_0_0.py
- `IN1608 xi` — extr_scaler_IN1608xi_Series_v1_1_3_0.py
- `IN1608 xi IPCP MA 70` — extr_scaler_IN1608xi_Series_v1_1_3_0.py
- `IN1608 xi IPCP SA` — extr_scaler_IN1608xi_Series_v1_1_3_0.py
- `IN1608 xi MA 70` — extr_scaler_IN1608xi_Series_v1_1_3_0.py
- `IN1608 xi SA` — extr_scaler_IN1608xi_Series_v1_1_3_0.py
- `IN1804` — extr_scaler_IN1804_Series_v1_2_4_0.py
- `IN1804 DI` — extr_scaler_IN1804_Series_v1_2_4_0.py
- `IN1804 DI/DO` — extr_scaler_IN1804_Series_v1_2_4_0.py
- `IN1804 DO` — extr_scaler_IN1804_Series_v1_2_4_0.py
- `IN1806` — extr_Scaler_IN806_IN1808_Series_v1_1_6_0.py
- `IN1808` — extr_Scaler_IN806_IN1808_Series_v1_1_6_0.py
- `IN1808 IPCP MA 70` — extr_Scaler_IN806_IN1808_Series_v1_1_6_0.py
- `IN1808 IPCP SA` — extr_Scaler_IN806_IN1808_Series_v1_1_6_0.py
- `IN2004` — extr_scaler_IN2004_Series_v1_0_3_0.py
- `IPL T PCS4i` — extr_controller_IPL_T_PCS4_IPL_T_PCS4I_v1220.py
- `MediaPort 200` — extr_other_MediaPort200_v1_3_0_0.py
- `NAVigator` — extr_sm_NAVigator_v1_0_1_4.py
- `ShareLink Pro 1100` — extr_cs_ShareLink.py
- `ShareLink Pro 2000` — extr_cs_ShareLink.py
- `SW2 HD 4K PLUS` — extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0.py
- `SW4 HD 4K PLUS` — extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0.py
- `SW6 HD 4K PLUS` — extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0.py
- `SW8 HD 4K PLUS` — extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0.py
