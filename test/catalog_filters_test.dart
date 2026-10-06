import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/catalog_filters.dart';

AvDeviceTemplate _t(String model, [String maker = '', String notes = '']) =>
    AvDeviceTemplate(
      model: model,
      manufacturer: maker,
      notes: notes,
      ports: const [],
    );

void main() {
  test('warranties are read off the name, not the notes', () {
    expect(
      isWarrantyItem(_t('Year 4 & 5 Extended Warranty with Advance Swap')),
      isTrue,
    );
    expect(
      isWarrantyItem(_t('3-Year Next Business Day Whole Unit Exchange, DC-30')),
      isTrue,
    );
    expect(
      isWarrantyItem(_t('5-Year Service Support with Projector Loaner')),
      isTrue,
    );
    expect(
      isWarrantyItem(_t('IN1608 xi', 'Extron', 'Switcher with DTP Extension')),
      isFalse,
    );
  });

  test('other markets are told from US models', () {
    String? m(String model, String maker) => nonUsMarket(_t(model, maker));
    expect(m('AC 102 UK', 'Extron'), 'UK');
    expect(m('DTP3 T 202 EU/MK', 'Extron'), 'Europe');
    expect(m('eLink 100 T AUS', 'Extron'), 'Australia');
    expect(m('ADP-USBC-AU-2X2', 'Extron'), isNull);
    expect(m('AC 102', 'Extron'), isNull);

    expect(m('CB-G7100', 'Epson'), 'Asia');
    expect(m('EB-L610U', 'Epson'), 'Europe');
    expect(m('EB-PU2010B', 'Epson'), isNull);
    expect(m('EB-PQ2216W', 'Epson'), isNull);
    expect(m('Pro G7100', 'Epson'), isNull);
    expect(m('PowerLite L610U', 'Epson'), isNull);

    expect(m('PT-SLW65CL', 'Panasonic'), 'China');
    expect(m('PT-FRW62C', 'Panasonic'), 'China');
    expect(m('PT-EW540E', 'Panasonic'), 'Europe / Asia');
    expect(m('PT-EZ770ZE', 'Panasonic'), 'Europe / Asia');
    expect(m('PT-FW430EA', 'Panasonic'), 'Europe / Asia');
    expect(m('PT-RZ570BT', 'Panasonic'), 'Asia');
    expect(m('PT-VMZ250T', 'Panasonic'), 'Asia');
    for (final us in [
      'PT-RZ570BU',
      'PT-RZ570',
      'PT-MZ14KLBU8',
      'PT-REZ12LBUG',
      'PT-EW540L',
      'PT-EX800Z',
      'PT-VMZ51S',
      'PT-RQ35KU',
    ]) {
      expect(m(us, 'Panasonic'), isNull, reason: us);
    }
  });

  test('over the shipped catalog, nothing US-made from Extron is hidden', () {
    final doc = jsonDecode(File('av_devices.json').readAsStringSync()) as Map;
    final all = [
      for (final d in doc['devices'] as List)
        AvDeviceTemplate.fromJson(Map<String, dynamic>.from(d as Map)),
    ];
    final warranties = all.where(isWarrantyItem).toList();
    expect(warranties.length, greaterThanOrEqualTo(60));
    // Every warranty hit is a misc line, never a product.
    expect(
      warranties.where((t) => t.category == 'Projector' ||
          t.category == 'Switcher'),
      isEmpty,
    );
    final foreignExtron = all
        .where((t) => t.manufacturer == 'Extron' && nonUsMarket(t) != null)
        .map((t) => t.model);
    for (final model in foreignExtron) {
      expect(
        RegExp(r'\b(UK|EU|AUS|CN|JP|MK)\b').hasMatch(model),
        isTrue,
        reason: model,
      );
    }
  });
}
