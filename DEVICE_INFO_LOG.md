# DEVICE_INFO rollout log

Generated 2026-07-16. Adds Room Config Builder `DEVICE_INFO` metadata to the
python driver modules in `device/`. Model lists come from each driver's own
`self.Models` dict when present, otherwise from the matching driver PDF in
`documentation/`. Connection ports were taken from the PDF connection examples
(`EthernetClass`/`SSHClass`); GUI names (btn/lbl/gve) follow the conventions
already used in `config.json`. Passwords, IPs and COM ports are left blank
(site-specific).

## Files changed (61)

| File | Type | Models | Model source | Connection | Keep-alive |
|---|---|---|---|---|---|
| avr_camera_PTZ310_PTZ330_v1_0_4_0.py | camera | 4: PTZ310, PTZ330, PTZ310W, PTZ330W | documentation PDF | UDP 52381 | Power / 10s |
| dali_controller.py | screen | 1: SCB-100 | documentation PDF | TCP 23 | None / 30s |
| dali_controller_SCB_100_v1_0_3_0.py | screen | none (fallback) | none declared | TCP 23 | None / 30s |
| epsn_vp_CB_EB_PowerLite_800F_805F_Series.py | projector | 6: EB-800F, EB-805F, PowerLite 800F, PowerLite 805F ... | documentation PDF | TCP 3629 | Power / 10s |
| epsn_vp_CB_EB_Powerlite_Brightlink_Series.py | projector | 27: BrightLink 695Wi, EB-695Wi, CB-695Wi, EB-685WT ... | driver self.Models | TCP 3629 | Power / 10s |
| epsn_vp_EB_CB_Pro_G7xxx_Series_v1_1_0_1.py | projector | 27: EB-G7800, EB-G7805, Pro G7800, Pro G7805 ... | documentation PDF | TCP 3629 | Power / 10s |
| epsn_vp_Powerlite.py | projector | 17: EB-L610W, EB-L610U, EB-L615U, EB-L510U ... | driver self.Models | TCP 3629 | Power / 10s |
| extr_Scaler_IN806_IN1808_Series_v1_1_6_0.py | switcher | 4: IN1808, IN1808 IPCP SA, IN1808 IPCP MA 70, IN1806 | driver self.Models | SSH 22023 | Temperature / 30s |
| extr_controller_IPL_T_PCS4_IPL_T_PCS4I_v1220.py | power | 2: IPL T PCS4, IPL T PCS4i | documentation PDF | TCP 23 | ExecutiveMode / 30s |
| extr_dsp_DMP64_v1_2_0_0.py | dsp | 1: DMP 64 | documentation PDF | TCP 23 | PartNumber / 30s |
| extr_dsp_DMP_128_Plus_Series.py | dsp | none (fallback) | none declared | SSH 22023 | PartNumber / 30s |
| extr_dsp_DMP_128_Plus_Series_v1_10_13_0.py | dsp | 6: DMP 128 Plus, DMP 128 Plus C, DMP 128 Plus C AT, DMP 128 Plus AT ... | driver self.Models | SSH 22023 | PartNumber / 30s |
| extr_dsp_DMP_64_Plus.py | dsp | none (fallback) | none declared | SSH 22023 | PartNumber / 30s |
| extr_dsp_DMP_64_Plus_Series.py | dsp | none (fallback) | none declared | SSH 22023 | PartNumber / 30s |
| extr_dsp_DMP_64_Plus_Series_v1_4_1_0.py | dsp | 4: DMP 64 Plus C, DMP 64 Plus C V, DMP 64 Plus C AT, DMP 64 Plus C V AT | driver self.Models | SSH 22023 | PartNumber / 30s |
| extr_matrix_DTP2CrossPoint_82_v1_1_0_0.py | switcher | 3: DTP2 Crosspoint 82, DTP2 Crosspoint 82 IPCP MA 70, DTP2 Crosspoint 82 IPCP SA | documentation PDF | SSH 22023 | RefreshMatrix / 30s |
| extr_matrix_DTPCrossPoint84_v1_5_6_0.py | switcher | 3: DTP CrossPoint 84, DTP CrossPoint 84 IPCP MA, DTP CrossPoint 84 IPCP SA | documentation PDF | TCP 23 | RefreshMatrix / 30s |
| extr_matrix_DTPCrossPoint_86_1084K.py | switcher | 6: DTP CrossPoint 108 4K, DTP CrossPoint 108 4K IPCP SA, DTP CrossPoint 108 4K IPCP MA 70, DTP CrossPoint 86 4K ... | driver self.Models | SSH 22023 | RefreshMatrix / 30s |
| extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py | switcher | none (fallback) | none declared | SSH 22023 | RefreshMatrix / 30s |
| extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1872.py | switcher | 6: DTP CrossPoint 82 4K, DTP CrossPoint 82 4K IPCP MA 70, DTP CrossPoint 82 4K IPCP SA, DTP CrossPoint 84 4K ... | driver self.Models | SSH 22023 | RefreshMatrix / 30s |
| extr_other_DTP_HD_DA4_4K_Series_v1_2_0_0.py | switcher | 4: DTP HD DA4 4K 230, DTP HD DA4 4K 330, DTP HD DA8 4K 230, DTP HD DA8 4K 330 | driver self.Models | SSH 22023 | PartNumber / 30s |
| extr_other_MediaPort200_v1_3_0_0.py | mediaport | 1: MediaPort 200 | documentation PDF | SSH 22023 | USBHostStatus / 60s |
| extr_scaler_IN1606_IN1608_Series_v1_7_0_0.py | switcher | 13: IN1606, IN1608, IN1608 MA, IN1608 SA ... | driver self.Models | SSH 22023 | Temperature / 30s |
| extr_scaler_IN1608xi_Series_v1_1_3_0.py | switcher | 5: IN1608 xi, IN1608 xi SA, IN1608 xi MA 70, IN1608 xi IPCP SA ... | driver self.Models | TCP 23 | Temperature / 30s |
| extr_scaler_IN1804_Series_v1_2_4_0.py | switcher | 4: IN1804, IN1804 DI, IN1804 DO, IN1804 DI/DO | documentation PDF | SSH 22023 | Temperature / 30s |
| extr_scaler_IN2004_Series_v1_0_3_0.py | switcher | 3: IN2004, DTP3 IN2004 DI/DO, DTP3 IN2004 DO | driver self.Models | SSH 22023 | Temperature / 30s |
| extr_sm_NAVigator_v1_0_1_4.py | switcher | 1: NAVigator | driver self.Models | SSH 22023 | RefreshMatrix / 30s |
| extr_sm_SMP_300_Series_v1_19_15_0.py | recorder | 4: SMP 351, SMP 351 3G-SDI, SMP 352, SMP 352 3G-SDI | driver self.Models | SSH 22023 | InputStatus / 30s |
| extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0.py | switcher | 4: SW2 HD 4K PLUS, SW4 HD 4K PLUS, SW6 HD 4K PLUS, SW8 HD 4K PLUS | driver self.Models | SSH 22023 | Input / 30s |
| extr_switcher_SW_HD_4K_Plus_Series_v1_1_5_0.py | switcher | none (fallback) | none declared | SSH 22023 | Input / 30s |
| hcam_doccam_Ultra_8_v1_1_0_0.py | doccam | 1: Ultra 8 | documentation PDF | Serial | Power / 10s |
| igen_switcher_Toggle.py | usb | 1: Toggle | documentation PDF | Serial | Input / 10s |
| infc_tdisplay_INF8640e.py | display | 3: INF6540e, INF7540e, INF8640e | documentation PDF | Serial | Power / 30s |
| infc_tdisplay_INFxx00_55_65_75_86_98_v1_0_0_0.py | display | 5: INF5500, INF6500, INF7500, INF8600 ... | documentation PDF | TCP 4660 | Power / 30s |
| krmr_VIA_GO.py | wireless | 2: VIA GO, VIA GO2 | documentation PDF | TCP 9982 | RoomCode / 30s |
| nec_display_C_751_861_981_Q.py | display | 3: C751Q, C861Q, C981Q | documentation PDF | TCP 7142 | Power / 30s |
| nec_display_E758_E868_E988_v1_0_2_0.py | display | 3: E758, E868, E988 | documentation PDF | TCP 7142 | Power / 30s |
| nec_display_E758_E868_v1_0_0_0.py | display | none (fallback) | none declared | TCP 7142 | Power / 30s |
| nec_display_MExx1_Series_v1_0_0_0.py | display | 4: ME431, ME501, ME551, ME651 | documentation PDF | TCP 7142 | Power / 30s |
| pana_camera_AW_HE_UE_Series.py | camera | 43: AW-HE100, AW-HE120, AW-HE38H, AW-HE38HK ... | documentation PDF | TCP 80 | Power / 10s |
| pana_vp_PTFRW_FRX_FRZ_RW_RX_RZ_Series_v1_1_0_0.py | projector | 13: PT-RW930, PT-RX110, PT-FRZ98C, PT-FRW93C ... | driver self.Models | TCP 1024 | Power / 10s |
| pana_vp_PTFW4xxEA_Series.py | projector | 6: PT-FW430U, PT-FW430E, PT-FW430EA, PT-FX400U ... | driver self.Models | TCP 1024 | Power / 10s |
| pana_vp_PT_BMX50_VMW50_VMW60_VMZ_Series_v1_110.py | projector | 9: PT-VMW50, PT-VMW50U, PT-VMZ250T, PT-VMZ60 ... | driver self.Models | TCP 1024 | Power / 10s |
| pana_vp_PT_BMZx1_VMWx1_VMZx1_Series_v1_0_3_0.py | projector | none (fallback) | none declared | TCP 1024 | Power / 10s |
| pana_vp_PT_EW_EX_EZ_SLW.py | projector | 29: PT-EZ770Z, PT-EW540L, PT-SLX80CL, PT-SLX75C ... | driver self.Models | TCP 1024 | Power / 10s |
| pana_vp_PT_RZ570_Series_v1_0_0_0.py | projector | 11: PT-RZ570, PT-RZ570B, PT-RZ570BA, PT-RZ570BD ... | documentation PDF | TCP 1024 | Power / 10s |
| pana_vp_VMZx.py | projector | 9: PT-VMZ51S, PT-BMZ51, PT-VMZ41, PT-VMZ71 ... | driver self.Models | TCP 1024 | Power / 10s |
| poly_vtc_Poly_Studio_X_Series_v1_3_3_0.py | vtc | 4: Poly Studio X50, Poly Studio X30, Poly Studio X70, Poly Studio X52 | documentation PDF | TCP 443 | None / 30s |
| ptz_camera_PT30XNDI_GY_WH.py | camera | 2: PT30X-NDI-GY, PT30X-NDI-WH | documentation PDF | TCP 5678 | Power / 10s |
| ptz_camera_USB_SDI_G2_Series.py | camera | 4: 12X-USB-G2, 20X-SDI-G2, 20X-USB-G2, 12X-SDI-G2 | documentation PDF | TCP 5678 | Power / 10s |
| shrp_display_4P_BxxEJ2U_Series_v1_0_2_0.py | display | 6: 4P-B75EJ2U, 4P-B65EJ2U, 4P-B55EJ2U, 4P-B50EJ2U ... | documentation PDF | TCP 10008 | Power / 30s |
| shrp_display_4T_BxxCJ1U_Series_v1_0_2_0.py | display | 3: 4T-B60CJ1U, 4T-B70CJ1U, 4T-B80CJ1U | documentation PDF | TCP 10002 | Power / 30s |
| shrp_display_LC_60C_xxLExxxU_Series.py | display | 23: LC-90LE657U, LC-60C6500U, LC-60C7500U, LC-60LE650U ... | documentation PDF | TCP 10002 | Power / 30s |
| shur_dsp_MXWAPXD2.py | dsp | 1: MXWAPXD2 | documentation PDF | TCP 2202 | SerialNumber / 30s |
| smsg_display_UNxxTU8000_Series_v1_0_1_0.py | display | 6: UN43TU8000, UN50TU8000, UN55TU8000, UN65TU8000 ... | documentation PDF | TCP 1516 | Power / 30s |
| sony_vp_VPL_FH700_Series_v1_0_6_0.py | projector | 2: VPL-FHZ700, VPL-FHZ700L | documentation PDF | TCP 53484 | Power / 10s |
| sony_vp_VPL_FHZ7x_Series_v1_0_0_0.py | projector | 2: VPL-FHZ70, VPL-FHZ75 | documentation PDF | TCP 53595 | Power / 10s |
| sony_vp_VPL_P_Series.py | projector | 4: VPL-PHZ60, VPL-P620HZ, VPL-PHZ50, VPL-P520HZ | documentation PDF | TCP 53595 | Power / 10s |
| sony_vp_VPL_P_Series_v1_0_1_0.py | projector | none (fallback) | none declared | TCP 53595 | Power / 10s |
| vadd_switcher_AV_Bridge_2x1.py | recorder | 1: AV Bridge 2x1 | documentation PDF | TCP 23 | Power / 30s |
| apc_other_AP79xxB_Series.py | power | 2: AP7921B, AP7922B | driver self.Models | TCP 23 | SerialNumber / 10s |

### Notes on individual files

- **dali_controller.py** - site copy - made DEFAULT for SCB-100; model from dali_controller_SCB_100_v1_0_3_0.pdf
- **dali_controller_SCB_100_v1_0_3_0.py** - SCB-100 deferred to site copy dali_controller
- **extr_dsp_DMP64_v1_2_0_0.py** - older driver: Ethernet port 23 per PDF
- **extr_dsp_DMP_128_Plus_Series.py** - duplicate of v1_10_13_0 - no models declared (dropdown entries via self.Models fallback)
- **extr_dsp_DMP_64_Plus.py** - duplicate of _Series_v1_4_1_0 - no models declared (dropdown entries via self.Models fallback)
- **extr_dsp_DMP_64_Plus_Series.py** - duplicate of _Series_v1_4_1_0 - no models declared (dropdown entries via self.Models fallback)
- **extr_matrix_DTPCrossPoint84_v1_5_6_0.py** - older driver: Ethernet port 23 per PDF (no SSH class)
- **extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871.py** - superseded by v1872 - no models declared (dropdown entries via self.Models fallback)
- **extr_other_DTP_HD_DA4_4K_Series_v1_2_0_0.py** - distribution amp - filed under 'switcher' (closest family)
- **extr_scaler_IN1608xi_Series_v1_1_3_0.py** - Ethernet port 23 per PDF (no SSH class in doc)
- **extr_sm_NAVigator_v1_0_1_4.py** - NAV system controller - filed under 'switcher'; SSH 22023 assumed (PDF has no connection example)
- **extr_switcher_SW_HD_4K_Plus_Series_v1_1_5_0.py** - superseded by v1_1_9_0 - no models declared (dropdown entries via self.Models fallback)
- **hcam_doccam_Ultra_8_v1_1_0_0.py** - serial-only per PDF; device_type 'doccam' matches no wizard family (visible via 'Show all device types')
- **infc_tdisplay_INF8640e.py** - models from 'INF 40 Series - RS232 Commands.html'; RS-232 control doc so serial connection
- **krmr_VIA_GO.py** - models/port from krmr_cs_VIA_GO_GO2_v1_0_1_0.pdf
- **nec_display_E758_E868_v1_0_0_0.py** - superseded by nec_display_E758_E868_E988_v1_0_2_0 (same models plus E988) - no models declared
- **pana_camera_AW_HE_UE_Series.py** - HTTP-based driver (HTTPClass port 80 per PDF)
- **pana_vp_PT_BMX50_VMW50_VMW60_VMZ_Series_v1_110.py** - PT-VMZ50/PT-VMZ50U left to pana_vp_VMZx (site copy) as default
- **pana_vp_PT_BMZx1_VMWx1_VMZx1_Series_v1_0_3_0.py** - all models deferred to pana_vp_VMZx (site copy); dropdown entries come from self.Models fallback
- **pana_vp_VMZx.py** - site copy - made DEFAULT for the VMZ/BMZ models over the versioned Extron files
- **poly_vtc_Poly_Studio_X_Series_v1_3_3_0.py** - HTTPS REST driver (port 443 per PDF); device_type 'vtc' matches no wizard family (visible via 'Show all device types')
- **shur_dsp_MXWAPXD2.py** - model/port from MXWneXt-command-strings.pdf (TCP 2202)
- **smsg_display_UNxxTU8000_Series_v1_0_1_0.py** - HTTP-based driver (HTTPClass port 1516 per PDF)
- **sony_vp_VPL_P_Series.py** - site copy referenced by config.json - made DEFAULT; models from sony_vp_VPL_P_Series_v1_0_1_0.pdf
- **sony_vp_VPL_P_Series_v1_0_1_0.py** - models deferred to the site copy sony_vp_VPL_P_Series; this file has no self.Models so it lists no models
- **vadd_switcher_AV_Bridge_2x1.py** - PDF model is 'AV Bridge 2x1'; config.json currently says 'AV Bridge' (won't match until updated)
- **apc_other_AP79xxB_Series.py** - REPLACED existing DEVICE_INFO: previous block had camera values (Btn_Con_Cam1 / UDP 52381) copy-pasted from the TR311 template; now matches config.json POWERDEVICE_1 conventions

## Files skipped (5)

- **avr_TR311.py** - already has DEVICE_INFO (left unchanged)
- **avr_camera_CAM570.py** - already has DEVICE_INFO (left unchanged)
- **dyds_other_DL3B_DL3W_LCD100_v1_0_1_0.py** - no self.Models and no matching PDF in documentation/ - skipped
- **extr_cs_ShareLink.py** - no self.Models and no matching PDF in documentation/ - skipped (config.json already binds it manually)
- **extr_switcher_DTP3_T_212_D_v1_0_0_0.py** - no self.Models and no matching PDF in documentation/ - skipped
