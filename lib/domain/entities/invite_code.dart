/// The shape of a pairing code — six characters from an unambiguous alphabet.
///
/// §7 fixes the format: **6 characters, no `O`, `0`, `I` or `1`.** The reason is
/// not entropy, it is that the code is **read aloud over the phone by an elderly
/// person**, so every character that sounds or looks like another one is a
/// family failing to pair and blaming the app.
///
/// ## Both sides of the wire implement this, and only one of them is authority
///
/// `functions/src/invites.ts` generates codes from the same alphabet, and that
/// copy is the one that matters: the client can be modified, so a code this
/// class would reject is still rejected by `redeemInvite` looking the document
/// up and finding nothing. Everything here is a **UX affordance** — catching a
/// typo before a round trip, and normalising what a person actually typed. It is
/// never a control, exactly as `AppServices.resolveWatchedLink` is never one.
///
/// The two copies are kept honest by `functions/test/invites.test.js`, which
/// asserts the alphabet string character for character against the one below.
abstract final class InviteCode {
  /// The 32 characters a code may contain.
  ///
  /// A–Z without `I` or `O`; 2–9 without `0` or `1`. 32^6 is about 1.07 billion
  /// codes, which is not the interesting number — single-use redemption behind a
  /// callable is what bounds guessing, and the expiry bounds how long any one
  /// code is worth guessing at.
  static const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static const int length = 6;

  /// [code] split for **reading aloud**, as two groups of three.
  ///
  /// Six unbroken characters is what people misread; the group boundary is what
  /// a reader uses to keep their place when the listener asks them to repeat it.
  /// Grouping is presentation only — [tryParse] strips it back out, so a person
  /// may type the spaces or not.
  static String forReading(String code) => code.length == length
      ? '${code.substring(0, 3)} ${code.substring(3)}'
      : code;

  /// What a person actually typed, turned into a code — or null if it cannot be
  /// one.
  ///
  /// **Lower case is accepted and upper-cased**, because a phone keyboard
  /// defaults to lower case and a code that only works in capitals would be this
  /// app's most common support call. **Spaces and hyphens are stripped**, so
  /// somebody who copies `K7R TQX` out of a message, or types the grouping they
  /// were read, is not punished for it.
  ///
  /// Everything else is rejected rather than repaired. In particular `O` is
  /// **not** silently read as `0` and `I` is not read as `1`: neither digit is in
  /// the alphabet either, so there is no character a substitution could arrive
  /// at, and guessing at what somebody meant is how a family ends up paired to
  /// the wrong person. The screen asks them to check the code instead.
  static String? tryParse(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.trim().toUpperCase().runes) {
      final char = String.fromCharCode(rune);
      // Both separators a human might introduce, and nothing else. A code is
      // never *created* with a hyphen — this accepts one because a person who
      // was read "K7R, TQX" may well type it.
      if (char == ' ' || char == '-') continue;
      if (!alphabet.contains(char)) return null;
      buffer.write(char);
    }
    final code = buffer.toString();
    return code.length == length ? code : null;
  }

  /// Whether [raw] is a code this build would send to `redeemInvite`.
  static bool isValid(String raw) => tryParse(raw) != null;
}
