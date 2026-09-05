# LZ4Factory.safeInstance() resolves these names, INSTANCE fields and the
# package-private HC(int) constructor through reflection. Keep the factory in
# the same package so reflective member access remains valid after R8.
-keep class net.jpountz.lz4.LZ4Factory {
    public static net.jpountz.lz4.LZ4Factory safeInstance();
    public net.jpountz.lz4.LZ4Compressor fastCompressor();
    public net.jpountz.lz4.LZ4SafeDecompressor safeDecompressor();
}
-keep class net.jpountz.lz4.LZ4JavaSafeCompressor { *; }
-keep class net.jpountz.lz4.LZ4HCJavaSafeCompressor { *; }
-keep class net.jpountz.lz4.LZ4JavaSafeFastDecompressor { *; }
-keep class net.jpountz.lz4.LZ4JavaSafeSafeDecompressor { *; }
