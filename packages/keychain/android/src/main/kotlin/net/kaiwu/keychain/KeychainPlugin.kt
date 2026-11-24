package net.kaiwu.keychain

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.UserManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.BufferUnderflowException
import java.security.KeyStore
import java.security.KeyStoreException
import java.security.NoSuchAlgorithmException
import java.security.NoSuchProviderException
import java.security.ProviderException
import java.security.SecureRandom
import java.security.UnrecoverableKeyException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The Android half of the Dart `KeychainDataSourceImpl`, over the
 *  `net.kaiwu.keychain` MethodChannel and its `/availability` EventChannel.
 *
 *  Keystore keys cannot be exported, so each key is two parts: a 256-bit
 *  random secret — the key the caller uses — sealed with AES-256-GCM by a
 *  Keystore key under the alias `ALIAS_PREFIX + keyId`. The sealed secret is
 *  a file in `noBackupFilesDir/keychain/`, which no backup or device transfer
 *  copies, and the Keystore key never leaves the device either. `read`
 *  unseals and answers with the secret, the same shape iOS answers with.
 *  StrongBox is asked for where the device has it and dropped where it does
 *  not. `store` seals 32 bytes made elsewhere (a cloud KMS data key, say)
 *  the same way, in place of the random secret.
 *
 *  A key exists when its sealed file exists. A file whose Keystore key is
 *  gone or cannot open it is `invalidated`, and left in place.
 *
 *  Errors are the package's closed vocabulary — `alreadyExists`, `notFound`,
 *  `invalidated`, `temporarilyUnavailable`, `unsupported` — or `failed`.
 *  Never the key id: it can be a record id.
 *
 *  Registered automatically by `GeneratedPluginRegistrant` on every engine; a
 *  consuming app makes no registration call of its own. */
class KeychainPlugin : FlutterPlugin {

    private val methodChannelName = "net.kaiwu.keychain"
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val messenger = binding.binaryMessenger
        eventChannel = EventChannel(messenger, "$methodChannelName/availability")
        eventChannel.setStreamHandler(NoAvailabilityChanges)

        methodChannel = MethodChannel(messenger, methodChannelName)
        methodChannel.setMethodCallHandler { call, result ->
            if (call.method == "isAvailable") {
                result.success(isUserUnlocked())
                return@setMethodCallHandler
            }
            val keyId = call.argument<String>("keyId")
            // Dart validates the id; checked again here because it becomes a
            // file name.
            if (keyId == null || !KEY_ID_FORMAT.matches(keyId)) {
                result.error("badArgs", "keyId is required", null)
                return@setMethodCallHandler
            }
            val operation: () -> Any? = when (call.method) {
                "create" -> { -> create(keyId) }
                "store" -> {
                    // Dart checks the length; checked again so a drifted
                    // caller can never seal a key that `read` would call
                    // unusable.
                    val material = call.argument<ByteArray>("material")
                    if (material == null || material.size != KEY_BYTE_COUNT) {
                        result.error("badArgs", "material is required", null)
                        return@setMethodCallHandler
                    }
                    val storeMaterial: () -> Any? = { store(keyId, material) }
                    storeMaterial
                }
                "read" -> { -> read(keyId) }
                "exists" -> { -> exists(keyId) }
                "delete" -> { -> delete(keyId) }
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            executor.execute {
                val answer = try {
                    Answer.Success(operation())
                } catch (e: KeychainFailure) {
                    Answer.Failure(e.code, null)
                } catch (e: Throwable) {
                    // Deliberately Throwable: whatever escapes, the call must still be
                    // answered, or Dart waits out its timeout. Any other fault is an
                    // unidentified failure, which the Dart side never reads as
                    // "absent" — unless the platform marks it transient.
                    val fault = keystoreFault(e)
                    Answer.Failure(
                        if (fault?.isTransient == true) "temporarilyUnavailable" else "failed",
                        fault?.numericErrorCode,
                    )
                }
                mainHandler.post {
                    when (answer) {
                        is Answer.Success -> result.success(answer.value)
                        is Answer.Failure ->
                            result.error(answer.code, "keychain operation failed", answer.diagnosticCode)
                    }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    /** No add-if-absent exists for a file plus a Keystore key, so the check
     *  and the create run on [executor], one process-wide thread: no other
     *  keychain call can land between them. A Keystore key left under the
     *  alias without a sealed file (an interrupted create) protects nothing,
     *  and generating over it replaces it. */
    private fun create(keyId: String): Any? {
        val secret = ByteArray(KEY_BYTE_COUNT)
        try {
            SecureRandom().nextBytes(secret)
            seal(keyId, secret)
        } finally {
            secret.fill(0)
        }
        return null
    }

    /** Key material made elsewhere (a cloud KMS data key, say), sealed and
     *  kept exactly like a secret [create] drew, under the same check. */
    private fun store(keyId: String, material: ByteArray): Any? {
        try {
            seal(keyId, material)
        } finally {
            material.fill(0)
        }
        return null
    }

    /** The add-if-absent behind [create] and [store]; runs on [executor]. */
    private fun seal(keyId: String, secret: ByteArray) {
        val file = sealedFile(keyId)
        if (file.exists()) {
            throw KeychainFailure("alreadyExists")
        }
        val wrappingKey = generateWrappingKey(ALIAS_PREFIX + keyId)
        val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
        cipher.updateAAD(keyId.toByteArray(Charsets.UTF_8))
        val sealed = cipher.doFinal(secret)
        writeAtomically(file, encode(cipher.iv, sealed))
    }

    private fun generateWrappingKey(alias: String): SecretKey {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                return generate(alias, strongBox = true)
            } catch (e: StrongBoxUnavailableException) {
                // StrongBox is optional hardware: fall through to the TEE.
            } catch (e: ProviderException) {
                // Some devices advertise StrongBox yet fail to generate in it;
                // still optional, so fall through to the TEE.
            }
        }
        return generate(alias, strongBox = false)
    }

    private fun generate(alias: String, strongBox: Boolean): SecretKey {
        val generator = try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        } catch (e: NoSuchAlgorithmException) {
            throw KeychainFailure("unsupported")
        } catch (e: NoSuchProviderException) {
            throw KeychainFailure("unsupported")
        }
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            spec.setIsStrongBoxBacked(true)
        }
        generator.init(spec.build())
        return generator.generateKey()
    }

    /** Unseals the secret. Any key that cannot be unsealed is left in place. */
    private fun read(keyId: String): Any? {
        val file = sealedFile(keyId)
        if (!file.exists()) {
            throw KeychainFailure("notFound")
        }
        val store = keyStore()
        val alias = ALIAS_PREFIX + keyId
        if (!store.containsAlias(alias)) {
            throw KeychainFailure("invalidated")
        }
        val key = try {
            store.getKey(alias, null)
        } catch (e: UnrecoverableKeyException) {
            throw KeychainFailure("invalidated")
        }
        if (key !is SecretKey) {
            throw KeychainFailure("invalidated")
        }
        val blob = decode(file.readBytes())
        val secret = try {
            val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, blob.iv))
            cipher.updateAAD(keyId.toByteArray(Charsets.UTF_8))
            cipher.doFinal(blob.sealed)
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw KeychainFailure("invalidated")
        } catch (e: AEADBadTagException) {
            // The file does not belong to this Keystore key, or was altered.
            throw KeychainFailure("invalidated")
        }
        if (secret.size != KEY_BYTE_COUNT) {
            secret.fill(0)
            throw KeychainFailure("invalidated")
        }
        return secret
    }

    private fun exists(keyId: String): Any? = sealedFile(keyId).exists()

    /** The file goes first: once it is gone the key is conclusively absent,
     *  and a Keystore key left behind is replaced by the next create. An
     *  entry already gone counts as deleted. */
    private fun delete(keyId: String): Any? {
        val file = sealedFile(keyId)
        if (file.exists() && !file.delete()) {
            throw KeychainFailure("failed")
        }
        stagingFile(file).delete()
        try {
            keyStore().deleteEntry(ALIAS_PREFIX + keyId)
        } catch (e: KeyStoreException) {
            // Best effort: the key is already absent, and the next create
            // replaces a Keystore key left under the alias.
        }
        return null
    }

    private fun sealedFile(keyId: String) = File(File(context.noBackupFilesDir, DIRECTORY), "$keyId.key")

    private fun stagingFile(target: File) = File(target.parentFile, target.name + ".part")

    /** Replaced whole or not at all: staged beside the target, synced, then
     *  renamed over it. The fixed staging name is safe because every write
     *  runs on [executor]. */
    private fun writeAtomically(target: File, bytes: ByteArray) {
        val directory = target.parentFile ?: throw KeychainFailure("failed")
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw KeychainFailure("failed")
        }
        val staging = stagingFile(target)
        FileOutputStream(staging).use { stream ->
            stream.write(bytes)
            stream.fd.sync()
        }
        if (!staging.renameTo(target)) {
            staging.delete()
            throw KeychainFailure("failed")
        }
        // The rename is durable only once the directory entry is: without
        // this a power loss could drop a key that create already reported
        // made, and the next create would mint a different one.
        val directoryFd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try {
            Os.fsync(directoryFd)
        } finally {
            Os.close(directoryFd)
        }
    }

    /** `[format version][iv length][iv][ciphertext + tag]`. */
    private fun encode(iv: ByteArray, sealed: ByteArray): ByteArray =
        ByteBuffer.allocate(2 + iv.size + sealed.size)
            .put(FILE_FORMAT_VERSION)
            .put(iv.size.toByte())
            .put(iv)
            .put(sealed)
            .array()

    private fun decode(bytes: ByteArray): SealedBlob {
        try {
            val buffer = ByteBuffer.wrap(bytes)
            if (buffer.get() != FILE_FORMAT_VERSION) {
                throw KeychainFailure("invalidated")
            }
            val iv = ByteArray(buffer.get().toInt() and 0xFF)
            buffer.get(iv)
            val sealed = ByteArray(buffer.remaining())
            buffer.get(sealed)
            // Exactly what create writes: a 12-byte GCM IV, and a sealed
            // 32-byte secret plus its 16-byte tag. Anything else would reach
            // the cipher as an unidentified failure instead.
            if (iv.size != GCM_IV_BYTES || sealed.size != KEY_BYTE_COUNT + GCM_TAG_BITS / 8) {
                throw KeychainFailure("invalidated")
            }
            return SealedBlob(iv, sealed)
        } catch (e: BufferUnderflowException) {
            throw KeychainFailure("invalidated")
        }
    }

    private fun keyStore(): KeyStore {
        val store = try {
            KeyStore.getInstance(KEYSTORE_PROVIDER)
        } catch (e: KeyStoreException) {
            // No AndroidKeyStore provider on this device.
            throw KeychainFailure("unsupported")
        }
        store.load(null)
        return store
    }

    /** Credential-encrypted storage, where the sealed files live, opens at the
     *  first unlock after boot and stays open until the next reboot. An app
     *  that is not `directBootAware` never runs before that unlock, so this is
     *  `true` in practice, and asked anyway so a direct-boot-aware app cannot
     *  read a locked store as an empty one. */
    private fun isUserUnlocked(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            // No direct-boot mode before Android 7: an app only runs unlocked.
            return true
        }
        val manager = context.getSystemService(Context.USER_SERVICE) as? UserManager
            ?: return true
        return manager.isUserUnlocked
    }

    /** Availability never changes while this process runs (see
     *  [isUserUnlocked]), so the stream sends nothing. Registered anyway so
     *  the Dart side's listen finds a handler. A `directBootAware` consuming
     *  app would need an `ACTION_USER_UNLOCKED` receiver here. */
    private object NoAvailabilityChanges : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {}

        override fun onCancel(arguments: Any?) {}
    }

    /** The platform Keystore error behind [e], which Android 13 adds: it tells a
     *  transient fault (the daemon busy or restarting) from a permanent one and
     *  carries a numeric code. Earlier releases have none, so their faults stay
     *  unidentified rather than being guessed temporary. */
    private fun keystoreFault(e: Throwable): KeystoreFault? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return null
        }
        var cause: Throwable? = e
        while (cause != null) {
            if (cause is android.security.KeyStoreException) {
                return KeystoreFault(cause.isTransientFailure, cause.numericErrorCode)
            }
            cause = cause.cause
        }
        return null
    }

    private sealed class Answer {
        class Success(val value: Any?) : Answer()
        class Failure(val code: String, val diagnosticCode: Int?) : Answer()
    }

    private class SealedBlob(val iv: ByteArray, val sealed: ByteArray)

    private class KeystoreFault(val isTransient: Boolean, val numericErrorCode: Int)

    private class KeychainFailure(val code: String) : Exception(code)

    companion object {
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val ALIAS_PREFIX = "net.kaiwu.keychain."
        private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val GCM_IV_BYTES = 12
        private const val KEY_BYTE_COUNT = 32
        private const val DIRECTORY = "keychain"
        private const val FILE_FORMAT_VERSION: Byte = 1

        /** The Dart `KeychainKeyIdEntity` format, length bound included. */
        private val KEY_ID_FORMAT = Regex("^(?=.{1,128}$)[a-z][a-z0-9_]*\\.[A-Za-z0-9][A-Za-z0-9_-]*$")

        /** One thread for the whole process, across engines: it is what makes
         *  check-then-create atomic for the whole app. */
        private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    }
}
