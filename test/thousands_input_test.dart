import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:extron_configurator/live_text_field.dart';

TextEditingValue _type(String before, String after, int cursor) =>
    ThousandsInputFormatter().formatEditUpdate(
      TextEditingValue(text: before),
      TextEditingValue(
        text: after,
        selection: TextSelection.collapsed(offset: cursor),
      ),
    );

void main() {
  test('a figure is grouped in thousands', () {
    expect(groupThousands('250000'), '250,000');
    expect(groupThousands('250000.00'), '250,000.00');
    expect(groupThousands('1234567.5'), '1,234,567.5');
    expect(groupThousands('999'), '999');
    expect(groupThousands(''), '');
    expect(groupThousands('\$250,000'), '250,000');
    expect(groupThousands('-12000'), '-12,000');
  });

  test('typing adds the commas and keeps the cursor at the end', () {
    final v = _type('25,000', '25,0000', 7);
    expect(v.text, '250,000');
    expect(v.selection.baseOffset, 7);
  });

  test('deleting a digit regroups and keeps the cursor after the same digit',
      () {
    // "1,250,000" with the 5 deleted (cursor was after it).
    final v = _type('1,250,000', '1,20,000', 3);
    expect(v.text, '120,000');
    expect(v.selection.baseOffset, 2);
  });
}
