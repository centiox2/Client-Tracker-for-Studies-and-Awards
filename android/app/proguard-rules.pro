# Text recognition (google_mlkit_text_recognition): only the Latin model is
# bundled. The plugin also references the Chinese, Devanagari, Japanese and
# Korean models, which are deliberately not included.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
