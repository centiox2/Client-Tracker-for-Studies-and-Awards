import 'package:flutter/material.dart';

/// The tag colours used in the Airtable "Applications Tracker", so a status,
/// school (RTO), country or assignee looks the same in the app as it does
/// there. Values not listed get a steady colour of their own.
class AirtableTags {
  AirtableTags._();

  // Airtable's palette: light, light (stronger), bright, dark.
  static const _palette = <String, Color>{
    'blueLight2': Color(0xFFCFDFFF),
    'cyanLight2': Color(0xFFD0F0FD),
    'tealLight2': Color(0xFFC2F5E9),
    'greenLight2': Color(0xFFD1F7C4),
    'yellowLight2': Color(0xFFFFEAB6),
    'orangeLight2': Color(0xFFFEE2D5),
    'redLight2': Color(0xFFFFDCE5),
    'pinkLight2': Color(0xFFFFDAF6),
    'purpleLight2': Color(0xFFEDE2FE),
    'grayLight2': Color(0xFFEEEEEE),
    'blueLight1': Color(0xFF9CC7FF),
    'cyanLight1': Color(0xFF77D1F3),
    'tealLight1': Color(0xFF72DDC3),
    'greenLight1': Color(0xFF93E088),
    'yellowLight1': Color(0xFFFFD66E),
    'orangeLight1': Color(0xFFFFA981),
    'redLight1': Color(0xFFFF9EB7),
    'pinkLight1': Color(0xFFF99DE2),
    'purpleLight1': Color(0xFFCDB0FF),
    'grayLight1': Color(0xFFCCCCCC),
    'blueBright': Color(0xFF2D7FF9),
    'cyanBright': Color(0xFF18BFFF),
    'tealBright': Color(0xFF20D9D2),
    'greenBright': Color(0xFF168A2E),
    'yellowBright': Color(0xFFFCB400),
    'orangeBright': Color(0xFFE5541A),
    'redBright': Color(0xFFE4144C),
    'pinkBright': Color(0xFFE30BB3),
    'purpleBright': Color(0xFF8B46FF),
    'grayBright': Color(0xFF666B74),
    'blueDark1': Color(0xFF2750AE),
    'cyanDark1': Color(0xFF0B76B7),
    'tealDark1': Color(0xFF167468),
    'greenDark1': Color(0xFF0B5E14),
    'yellowDark1': Color(0xFFB0640A),
    'orangeDark1': Color(0xFFA8350F),
    'redDark1': Color(0xFFB0164A),
    'pinkDark1': Color(0xFFA9138C),
    'purpleDark1': Color(0xFF6131B5),
    'grayDark1': Color(0xFF3F434B),
  };

  /// The Applications Tracker's Status options.
  static const _status = {
    'compliance and verification ongoing': 'tealLight2',
    'statement building': 'purpleLight1',
    'pending school allocation': 'redBright',
    'application to be submitted': 'cyanBright',
    'awaiting offer letter': 'tealBright',
    'to submit gte documents': 'greenLight2',
    'awaiting gte outcome': 'cyanLight2',
    'to pay school fees': 'blueLight2',
    'to deposit blocked account': 'orangeLight2',
    'cas received': 'greenLight1',
    'coe issued/done': 'redDark1',
    'on hold': 'blueBright',
    'drop out': 'purpleLight1',
    'withdrawn': 'yellowLight2',
    'refunded': 'grayLight2',
  };

  static const _country = {
    'uk': 'blueLight2',
    'germany': 'cyanLight2',
    'canada': 'tealLight2',
    'australia': 'greenLight2',
    'newzealand': 'orangeLight1',
    'new zealand': 'cyanBright',
  };

  static const _assignee = {
    'joy': 'greenBright',
    'ian': 'yellowBright',
    'collins': 'orangeDark1',
    'winnie': 'grayBright',
    'mourine': 'redBright',
    'yego': 'blueLight2',
    'cynthia': 'blueBright',
    'witney': 'grayLight1',
  };

  /// RTO (school) options, from the Airtable field's colour list.
  static const _rto = {
    'waifs': 'blueLight2',
    'flinders-gsp': 'cyanLight2',
    'ahmi': 'tealLight2',
    'npa': 'greenLight2',
    'kcbt': 'yellowLight2',
    'ihna': 'orangeLight2',
    'ihm': 'redLight2',
    'ismt': 'pinkLight2',
    'box hill': 'purpleLight2',
    'scu-gold coast': 'grayLight2',
    'scu-perth': 'blueLight1',
    'niagra collage': 'redBright',
    'uow': 'orangeLight2',
    'uow-bada': 'purpleBright',
    'acu': 'redLight2',
    'apeiro': 'yellowLight2',
    'holmesglen': 'blueLight1',
    'steinbis uni': 'yellowDark1',
    'thompson rivers university': 'greenLight1',
    'srh univeristy': 'pinkBright',
    'sheridan collage': 'tealBright',
    'lincoln uni': 'purpleDark1',
    'george brown poly': 'redLight1',
    'cqu': 'orangeDark1',
    'unitec': 'purpleLight1',
    'anglian ruskin': 'blueBright',
    'norther lights collage': 'cyanLight2',
    'eu': 'pinkDark1',
    'ue': 'orangeLight1',
    'swinburne': 'greenDark1',
    'victoria': 'cyanLight1',
    'leaders': 'tealLight1',
    'aibti': 'purpleLight1',
    'aru': 'greenLight2',
    'rosehill': 'tealDark1',
    'brooklyn': 'yellowLight1',
    'massey univeristy': 'grayBright',
    'georgian collage': 'cyanBright',
    'victoria university': 'grayLight1',
    'sae': 'greenLight2',
    'schiller university': 'redLight1',
    'arden uni': 'yellowBright',
    'cihe': 'redLight2',
    'ue germany': 'blueDark1',
    'edinburgh napier university': 'cyanDark1',
    'srh uni': 'yellowDark1',
    'uni of greenwich int coll': 'redBright',
    'ati': 'pinkLight1',
    'cq university': 'yellowLight2',
    'acknowledge education': 'purpleBright',
    'avta + pivot': 'grayBright',
    'deakin university': 'pinkDark1',
    'avta+aibt': 'grayLight1',
    'wollongong': 'yellowLight1',
    'charles sturt': 'grayLight2',
    'anu': 'tealBright',
    'rmiit': 'blueLight1',
    'aihe': 'greenLight1',
    'aibt/avta': 'cyanLight2',
    'uk': 'cyanBright',
    'sia': 'purpleDark1',
    'national diversity': 'orangeLight1',
    'stanley college': 'purpleLight2',
    'brighton college': 'grayDark1',
    'acknowlege': 'blueBright',
    'tafe': 'orangeDark1',
    'kaplan': 'pinkBright',
    'crown institute': 'greenBright',
    'torrens university': 'redDark1',
    'bic + pivot': 'tealLight2',
    'kicbt': 'orangeLight2',
    'murdoch': 'pinkDark1',
    'ecu': 'cyanDark1',
    'vit': 'blueBright',
    'acknowledge': 'orangeDark1',
    'naps': 'redLight1',
    'cocoon': 'tealDark1',
    'atc': 'grayBright',
    'aibt': 'orangeBright',
    'sunbeam': 'purpleLight1',
    'sihe': 'pinkLight2',
    'bic': 'orangeBright',
    'eit': 'redDark1',
    'asia': 'orangeLight1',
    'kaplan-gsp': 'purpleBright',
    'kbs-perth': 'blueDark1',
    'notre dame': 'greenLight1',
    'seattle': 'grayLight1',
    'apiero': 'grayDark1',
    'cihe-gsp': 'redBright',
    'apiero-gsp': 'cyanBright',
    'avta': 'pinkLight1',
    'astute': 'yellowLight1',
    'scu- melbourne': 'cyanLight1',
    'scu-melbourne': 'cyanLight1',
    'scu-sydney': 'tealLight1',
    'uow-gsp': 'blueLight2',
    'adci': 'pinkBright',
    'reach': 'greenBright',
    'sap creative media': 'purpleDark1',
    'sae creative media': 'tealBright',
    'sydney met': 'blueLight2',
    'acap': 'greenDark1',
    'federation university': 'yellowBright',
    'mihe': 'yellowDark1',
  };

  static const _fallback = [
    'blueLight2',
    'cyanLight2',
    'tealLight2',
    'greenLight2',
    'yellowLight2',
    'orangeLight2',
    'redLight2',
    'pinkLight2',
    'purpleLight2',
  ];

  static String _name(Map<String, String> known, String value) {
    final k = value.trim().toLowerCase();
    final hit = known[k];
    if (hit != null) return hit;
    // Unknown: a steady colour from the text, so it stays the same.
    var h = 0;
    for (final c in k.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _fallback[h % _fallback.length];
  }

  static Color _color(String name) => _palette[name]!;

  /// Light tags take dark text; bright and dark ones white (yellow bright
  /// keeps dark text, as in Airtable).
  static bool _darkText(String name) =>
      name.contains('Light') || name == 'yellowBright';

  static (Color, Color) status(String v) => _pair(_name(_status, v));
  static (Color, Color) rto(String v) => _pair(_name(_rto, v));
  static (Color, Color) country(String v) => _pair(_name(_country, v));
  static (Color, Color) assignee(String v) => _pair(_name(_assignee, v));

  /// The status colour on its own (charts).
  static Color statusColor(String v) => _color(_name(_status, v));

  static (Color, Color) _pair(String name) =>
      (_color(name), _darkText(name) ? const Color(0xFF1D1F25) : Colors.white);
}

/// A rounded tag, as in Airtable.
class TagChip extends StatelessWidget {
  const TagChip(this.label, this.colors, {super.key, this.dense = false});

  final String label;
  final (Color, Color) colors;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (label.trim().isEmpty) return const SizedBox.shrink();
    final (bg, fg) = clarityTagColors(colors.$1, Theme.of(context).brightness);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: fg,
          fontFamily: 'Inter',
          fontSize: dense ? 12 : 13,
          fontWeight: FontWeight.w500,
          height: 1.35,
        ),
      ),
    );
  }
}

/// Airtable's tag colour, the Clarity way: the same hue as a pale tint with
/// darker text (light), or a faint tint with light text (dark) — so a
/// status keeps the colour the team knows from Airtable without the loud
/// fill. Greys become the neutral pill.
(Color, Color) clarityTagColors(Color airtable, Brightness brightness) {
  final hsl = HSLColor.fromColor(airtable);
  final light = brightness == Brightness.light;
  if (hsl.saturation < 0.12) {
    return light
        ? (const Color(0xFFF2F4F7), const Color(0xFF475467))
        : (const Color(0xFF222A36), const Color(0xFFB8C1CE));
  }
  final sat = hsl.saturation.clamp(0.45, 0.85).toDouble();
  if (light) {
    return (
      HSLColor.fromAHSL(1, hsl.hue, sat, 0.94).toColor(),
      HSLColor.fromAHSL(1, hsl.hue, sat, 0.28).toColor(),
    );
  }
  return (
    HSLColor.fromAHSL(1, hsl.hue, sat * 0.55, 0.18).toColor(),
    HSLColor.fromAHSL(1, hsl.hue, sat, 0.78).toColor(),
  );
}
