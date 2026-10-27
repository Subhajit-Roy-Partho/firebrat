/// Voice casting + emotion-aware delivery for the expressive on-device mode.
///
/// Voice catalogs: Kokoro v1.0 (28 English voices) and Piper's multi-speaker
/// libritts_r model (904 speakers, 27 curated here). [kKokoroV1Voices] records for each its
/// gender and accent, the model card's overall quality grade, and a MEASURED
/// median speaking pitch (autocorrelation F0 over a 10 s test passage, fp32
/// graph on a laptop; see docs/handover/android-expressive-gpu.md). Casting
/// matches character age/gender/accent/temperament to those pitches, never
/// gives a character the narrator's voice, and fixes the choice for the whole
/// book (it is persisted with the cast and reused on resume).
library;

import 'dart:math' as math;

import 'cast_models.dart';

class VoiceProfile {
  final String name; // engine voice id: Kokoro file stem (af_heart) or `libritts_<sid>`
  final bool female;
  final bool british;

  /// Median fundamental frequency of a measured sample (Hz).
  final double f0;

  /// Model-card overall grade as 0..1 (A=1.0 ... F+=0.1).
  final double quality;
  const VoiceProfile(this.name, this.female, this.british, this.f0, this.quality);

  String get gender => female ? 'female' : 'male';
  String get label {
    if (name.startsWith('libritts_')) return 'Speaker ${name.substring(9)}';
    final base = name.substring(3);
    return '${base[0].toUpperCase()}${base.substring(1)}';
  }
}

/// Source-compatible name from before the voice catalogs were generalised.
typedef KokoroVoiceProfile = VoiceProfile;

const kKokoroV1Voices = <VoiceProfile>[
  VoiceProfile('af_heart', true, false, 195.1, 1.0),
  VoiceProfile('af_bella', true, false, 201.7, 0.9),
  VoiceProfile('af_nicole', true, false, 155.8, 0.7),
  VoiceProfile('af_aoede', true, false, 175.2, 0.6),
  VoiceProfile('af_kore', true, false, 150.0, 0.6),
  VoiceProfile('af_sarah', true, false, 192.0, 0.6),
  VoiceProfile('af_nova', true, false, 160.0, 0.5),
  VoiceProfile('af_alloy', true, false, 143.7, 0.5),
  VoiceProfile('af_sky', true, false, 153.8, 0.4),
  VoiceProfile('af_jessica', true, false, 208.7, 0.3),
  VoiceProfile('af_river', true, false, 169.0, 0.3),
  VoiceProfile('am_fenrir', false, false, 142.0, 0.6),
  VoiceProfile('am_michael', false, false, 121.8, 0.6),
  VoiceProfile('am_puck', false, false, 111.6, 0.6),
  VoiceProfile('am_echo', false, false, 112.7, 0.3),
  VoiceProfile('am_eric', false, false, 152.9, 0.3),
  VoiceProfile('am_liam', false, false, 129.4, 0.3),
  VoiceProfile('am_onyx', false, false, 88.9, 0.3),
  VoiceProfile('am_santa', false, false, 172.7, 0.2),
  VoiceProfile('am_adam', false, false, 121.2, 0.1),
  VoiceProfile('bf_emma', true, true, 182.5, 0.7),
  VoiceProfile('bf_isabella', true, true, 205.1, 0.5),
  VoiceProfile('bf_alice', true, true, 212.4, 0.3),
  VoiceProfile('bf_lily', true, true, 200.0, 0.3),
  VoiceProfile('bm_fable', false, true, 123.7, 0.5),
  VoiceProfile('bm_george', false, true, 139.5, 0.5),
  VoiceProfile('bm_lewis', false, true, 96.4, 0.4),
  VoiceProfile('bm_daniel', false, true, 127.0, 0.3),
];

/// Curated Piper en_US libritts_r speakers (speaker id = number in the name).
/// Picked from a sweep of 302 speakers: voiced-speech ratio >= 0.5, no numeric
/// failures, spread evenly over the measured pitch range (female >= 185 Hz,
/// male <= 135 Hz). Quality is not graded by the model authors, so it is flat.
const kPiperLibrittsVoices = <VoiceProfile>[
  VoiceProfile('libritts_657', true, false, 185.0, 0.5),
  VoiceProfile('libritts_759', true, false, 187.0, 0.5),
  VoiceProfile('libritts_777', true, false, 190.0, 0.5),
  VoiceProfile('libritts_282', true, false, 193.0, 0.5),
  VoiceProfile('libritts_537', true, false, 202.0, 0.5),
  VoiceProfile('libritts_579', true, false, 206.0, 0.5),
  VoiceProfile('libritts_108', true, false, 208.0, 0.5),
  VoiceProfile('libritts_171', true, false, 212.0, 0.5),
  VoiceProfile('libritts_18', true, false, 216.0, 0.5),
  VoiceProfile('libritts_15', true, false, 220.0, 0.5),
  VoiceProfile('libritts_525', true, false, 227.0, 0.5),
  VoiceProfile('libritts_57', true, false, 235.0, 0.5),
  VoiceProfile('libritts_150', true, false, 240.0, 0.5),
  VoiceProfile('libritts_699', true, false, 251.0, 0.5),
  VoiceProfile('libritts_132', false, false, 92.0, 0.5),
  VoiceProfile('libritts_831', false, false, 103.0, 0.5),
  VoiceProfile('libritts_435', false, false, 105.0, 0.5),
  VoiceProfile('libritts_636', false, false, 109.0, 0.5),
  VoiceProfile('libritts_813', false, false, 112.0, 0.5),
  VoiceProfile('libritts_375', false, false, 114.0, 0.5),
  VoiceProfile('libritts_414', false, false, 119.0, 0.5),
  VoiceProfile('libritts_528', false, false, 119.0, 0.5),
  VoiceProfile('libritts_834', false, false, 125.0, 0.5),
  VoiceProfile('libritts_825', false, false, 126.0, 0.5),
  VoiceProfile('libritts_495', false, false, 127.0, 0.5),
  VoiceProfile('libritts_690', false, false, 131.0, 0.5),
  VoiceProfile('libritts_243', false, false, 134.0, 0.5),
];

int piperSpeakerId(String voiceName) => int.tryParse(voiceName.replaceFirst('libritts_', '')) ?? 0;

VoiceProfile? findV1Voice(String? name) {
  if (name == null) return null;
  final n = name.trim().toLowerCase();
  for (final v in kKokoroV1Voices) {
    if (v.name == n || v.label.toLowerCase() == n) return v;
  }
  return null;
}

/// How a character is voiced: a Kokoro voice plus gentle per-character delivery.
class VoiceAssignment {
  final String voice;
  final double speedMul;
  final double semitones;
  final String reason;
  const VoiceAssignment(this.voice, {this.speedMul = 1.0, this.semitones = 0, this.reason = ''});
  Map<String, dynamic> toJson() => {'voice': voice, 'speed': speedMul, 'semitones': semitones, 'reason': reason};
  factory VoiceAssignment.fromJson(Map j) => VoiceAssignment(j['voice'].toString(),
      speedMul: (j['speed'] as num?)?.toDouble() ?? 1.0, semitones: (j['semitones'] as num?)?.toDouble() ?? 0,
      reason: j['reason']?.toString() ?? '');
}

double _targetF0(CastCharacter c, bool female) {
  var f = female
      ? switch (c.age) { 'child' => 215.0, 'young' => 200.0, 'elder' => 150.0, _ => 185.0 }
      : switch (c.age) { 'child' => 175.0, 'young' => 140.0, 'elder' => 95.0, _ => 120.0 };
  final t = c.temperament.toLowerCase();
  if (RegExp(r'gruff|stern|grave|deep|gloomy|menac|sinister|imperious|stoic').hasMatch(t)) f *= 0.93;
  if (RegExp(r'cheerful|bright|energetic|excit|playful|lively|eager|timid|nervous|shy').hasMatch(t)) f *= 1.06;
  return f;
}

/// Assigns every character a voice. [available] limits the pool to voices that
/// are downloaded (default: all). [overrides] (character name -> voice name)
/// win. The narrator's voice is never reused for a character. Deterministic:
/// characters are processed in id order (most important first).
Map<String, VoiceAssignment> assignVoices(List<CastCharacter> characters,
    {required String narratorVoice,
    List<VoiceProfile> catalog = kKokoroV1Voices,
    Set<String>? available,
    Map<String, String> overrides = const {},
    Map<String, VoiceAssignment> existing = const {}}) {
  final pool = [for (final v in catalog) if (available == null || available.contains(v.name)) v];
  final out = <String, VoiceAssignment>{};
  final used = <String, int>{narratorVoice: 1000};
  final ovr = {for (final e in overrides.entries) normOverrideKey(e.key): e.value};
  final ordered = [...characters]..sort((a, b) => a.id.compareTo(b.id));
  // Keep earlier decisions (resume): a character's voice is fixed for the book.
  for (final c in ordered) {
    final prior = existing[c.id];
    if (prior != null && prior.voice != narratorVoice && (available == null || available.contains(prior.voice))) {
      out[c.id] = prior;
      used[prior.voice] = (used[prior.voice] ?? 0) + 1;
    }
  }
  for (final c in ordered) {
    if (out.containsKey(c.id)) continue;
    final forced = _find(catalog, ovr[normOverrideKey(c.name)]);
    if (forced != null && forced.name != narratorVoice && pool.any((v) => v.name == forced.name)) {
      out[c.id] = VoiceAssignment(forced.name, reason: 'chosen by you');
      used[forced.name] = (used[forced.name] ?? 0) + 1;
      continue;
    }
    // Unknown gender: alternate by index so unknown speakers are spread out.
    final female = switch (c.gender) {
      'female' => true,
      'male' => false,
      _ => ordered.indexOf(c).isOdd,
    };
    var candidates = pool.where((v) => v.female == female && v.name != narratorVoice).toList();
    if (candidates.isEmpty) candidates = pool.where((v) => v.name != narratorVoice).toList();
    if (candidates.isEmpty) {
      out[c.id] = VoiceAssignment(narratorVoice, reason: 'no other voice installed');
      continue;
    }
    final target = _targetF0(c, female);
    double score(VoiceProfile v) {
      var s = (math.log(v.f0 / target)).abs() * 3.0; // pitch distance in log space
      s += (1 - v.quality) * 0.45;
      s += (used[v.name] ?? 0) * 1.5; // strongly prefer a voice nobody has yet
      if (c.accent == 'british' && !v.british) s += 0.5;
      if (c.accent == 'american' && v.british) s += 0.5;
      return s;
    }

    candidates.sort((a, b) {
      final d = score(a).compareTo(score(b));
      return d != 0 ? d : a.name.compareTo(b.name);
    });
    final best = candidates.first;
    final reuse = used[best.name] ?? 0;
    // A voice shared by a second character gets a small pitch/speed offset so
    // the two stay distinguishable.
    final semis = reuse == 0 ? 0.0 : (reuse.isOdd ? 1.5 : -1.5) * ((reuse + 1) ~/ 2).clamp(1, 2);
    final speed = reuse == 0 ? 1.0 : (reuse.isOdd ? 1.04 : 0.96);
    out[c.id] = VoiceAssignment(best.name,
        speedMul: speed,
        semitones: semis,
        reason: '${c.gender} ${c.age}, ${best.f0.round()} Hz voice${reuse > 0 ? ', shared (pitch shifted)' : ''}');
    used[best.name] = reuse + 1;
  }
  return out;
}

VoiceProfile? _find(List<VoiceProfile> catalog, String? name) {
  if (name == null) return null;
  final n = name.trim().toLowerCase();
  for (final v in catalog) {
    if (v.name == n || v.label.toLowerCase() == n) return v;
  }
  return null;
}

String normOverrideKey(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

// --- emotion-aware delivery ---

/// How a line is spoken within what Kokoro supports: its `speed` input, silence
/// around the line, and light gain / pitch applied to the audio afterwards.
class Delivery {
  final double speed; // multiplier of the base speed
  final int preMs;
  final int postMs;
  final double gainDb;
  final double semitones;
  const Delivery({this.speed = 1.0, this.preMs = 0, this.postMs = 0, this.gainDb = 0, this.semitones = 0});

  Delivery operator +(Delivery o) => Delivery(
        speed: speed * o.speed, preMs: preMs + o.preMs, postMs: postMs + o.postMs,
        gainDb: gainDb + o.gainDb, semitones: semitones + o.semitones);

  /// Keeps everything in a range that still sounds natural.
  Delivery clamped() => Delivery(
        speed: speed.clamp(0.78, 1.25).toDouble(), preMs: preMs.clamp(0, 400), postMs: postMs.clamp(0, 600),
        gainDb: gainDb.clamp(-8.0, 4.0).toDouble(), semitones: semitones.clamp(-1.8, 1.8).toDouble());
}

/// Emotion -> delivery table (see the handover doc for the reasoning). Values
/// are deliberately modest: Kokoro has no emotion control, so this only adds
/// tempo, pauses, loudness and a touch of pitch.
const kEmotionDelivery = <String, Delivery>{
  'neutral': Delivery(),
  'joy': Delivery(speed: 1.06, postMs: 30, gainDb: 1.0, semitones: 0.6),
  'sadness': Delivery(speed: 0.88, preMs: 80, postMs: 140, gainDb: -2.0, semitones: -0.6),
  'anger': Delivery(speed: 1.08, postMs: 60, gainDb: 2.5, semitones: -0.3),
  'fear': Delivery(speed: 1.10, preMs: 20, postMs: 50, gainDb: -1.0, semitones: 0.9),
  'surprise': Delivery(speed: 1.04, preMs: 90, gainDb: 1.0, semitones: 1.0),
  'tenderness': Delivery(speed: 0.92, preMs: 50, postMs: 110, gainDb: -3.0, semitones: 0.0),
  'sarcasm': Delivery(speed: 0.95, preMs: 40, postMs: 70, gainDb: 0.0, semitones: -0.4),
  'disgust': Delivery(speed: 0.94, preMs: 40, postMs: 60, gainDb: -0.5, semitones: -0.6),
  'awe': Delivery(speed: 0.90, preMs: 100, postMs: 130, gainDb: -1.0, semitones: 0.2),
  'suspense': Delivery(speed: 0.90, preMs: 90, postMs: 90, gainDb: -3.0, semitones: -0.2),
};

/// Stage-direction keywords (the LLM's free-text `delivery`) -> extra delivery.
final _deliveryKeywords = <RegExp, Delivery>{
  RegExp(r'whisper|hushed|murmur|under (his|her|their) breath|softly|quietly'): const Delivery(speed: 0.94, gainDb: -5.0),
  RegExp(r'shout|yell|scream|bellow|roar|cried out|exclaim'): const Delivery(speed: 1.05, gainDb: 3.0, semitones: 0.3),
  RegExp(r'slow|deliberate|measured|drawl|dragging'): const Delivery(speed: 0.88),
  RegExp(r'quick|hurried|rushed|breathless|rapid|fast|eager'): const Delivery(speed: 1.10),
  RegExp(r'trembl|quaver|shak|stammer|nervous|hesitant'): const Delivery(speed: 0.97, preMs: 40, semitones: 0.4),
  RegExp(r'cold|icy|flat|dry|stern|curt|clipped'): const Delivery(speed: 0.97, semitones: -0.4),
  RegExp(r'sob|weep|tearful|choked|crying'): const Delivery(speed: 0.88, preMs: 60, semitones: 0.3),
  RegExp(r'laugh|giggl|chuckl|amused|merr'): const Delivery(speed: 1.05, gainDb: 0.5, semitones: 0.5),
  RegExp(r'pause|trailing|trailed off|faint'): const Delivery(postMs: 120, gainDb: -1.5),
};

/// Combined delivery for [emotion] plus the free-text [delivery] direction.
Delivery deliveryFor(String emotion, [String delivery = '']) {
  var d = kEmotionDelivery[emotion] ?? kEmotionDelivery['neutral']!;
  final text = delivery.toLowerCase();
  if (text.isNotEmpty) {
    var hits = 0;
    for (final e in _deliveryKeywords.entries) {
      if (e.key.hasMatch(text) && hits < 2) {
        d = d + e.value;
        hits++;
      }
    }
  }
  return d.clamped();
}

/// Narration follows the page's mood only slightly (tempo), so a tense page is
/// read a touch slower and a joyful one a touch brighter.
Delivery narrationDeliveryFor(String? pageEmotion) {
  final d = kEmotionDelivery[pageEmotion ?? 'neutral'] ?? kEmotionDelivery['neutral']!;
  return Delivery(speed: 1 + (d.speed - 1) * 0.4, gainDb: d.gainDb * 0.3, semitones: d.semitones * 0.3).clamped();
}

// --- audio post-processing (pure, testable) ---

/// Scales by [gainDb] and shifts pitch by [semitones] through resampling; the
/// caller compensates the tempo change by passing `speed / ratio` to the TTS.
List<double> applyGainAndPitch(List<double> samples, {double gainDb = 0, double semitones = 0}) {
  final gain = math.pow(10, gainDb / 20).toDouble();
  final ratio = math.pow(2, semitones / 12).toDouble();
  final n = ratio == 1.0 ? samples.length : (samples.length / ratio).floor();
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final pos = i * ratio;
    final i0 = pos.floor();
    final frac = pos - i0;
    final a = samples[i0.clamp(0, samples.length - 1)];
    final b = samples[(i0 + 1).clamp(0, samples.length - 1)];
    out[i] = ((a + (b - a) * frac) * gain).clamp(-1.0, 1.0).toDouble();
  }
  return out;
}
