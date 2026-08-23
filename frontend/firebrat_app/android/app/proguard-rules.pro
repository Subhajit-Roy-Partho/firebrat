# google_mlkit_text_recognition's base API references optional
# language-specific recognizer classes (Chinese/Japanese/Korean/Devanagari)
# that live in separate packages this app doesn't depend on (only Latin
# script recognition is used — see mobile-Backend/lib/src/extraction/ocr_fallback.dart).
# R8 fails release minification without these, since it can't resolve
# classes it can see referenced but not find on the classpath. Safe to
# silence: the app never calls into those recognizer variants at runtime.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
