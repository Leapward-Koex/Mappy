package com.leapwardkoex.mappy

import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/** Cancellation is scoped to a consumer; shared work gets its own token. */
class TileCancellationToken {
    private val lock = Any()
    private var cancelled = false
    private val listeners = mutableSetOf<() -> Unit>()

    val isCancelled: Boolean get() = synchronized(lock) { cancelled }

    fun cancel() {
        val callbacks = synchronized(lock) {
            if (cancelled) return
            cancelled = true
            listeners.toList().also { listeners.clear() }
        }
        callbacks.forEach { runCatching(it) }
    }

    fun throwIfCancelled() {
        if (isCancelled) throw ProviderOperationCancelledException()
    }

    fun register(listener: () -> Unit): AutoCloseable {
        val callNow = synchronized(lock) {
            if (cancelled) true else { listeners.add(listener); false }
        }
        if (callNow) listener()
        return AutoCloseable { synchronized(lock) { listeners.remove(listener) } }
    }
}

/** Neither cancellation nor an old completion can remove a replacement job. */
internal class SharedTileJobs<K, V> {
    private val lock = Any()
    private val jobs = mutableMapOf<K, Job<V>>()

    internal class Job<V> {
        val cancellation = TileCancellationToken()
        val result = CompletableFuture<V>()
        var consumers = 0
    }

    inner class Lease internal constructor(
        private val key: K,
        private val job: Job<V>,
        val isOwner: Boolean,
        private val consumer: TileCancellationToken
    ) : AutoCloseable {
        private val released = AtomicBoolean(false)
        private var registration: AutoCloseable? = null
        val cancellation: TileCancellationToken get() = job.cancellation

        internal fun listen() { registration = consumer.register { close() } }

        fun runIfOwner(block: (TileCancellationToken) -> V) {
            if (!isOwner) return
            try {
                job.cancellation.throwIfCancelled()
                job.result.complete(block(job.cancellation))
            } catch (failure: Throwable) {
                job.result.completeExceptionally(failure)
            } finally {
                synchronized(lock) { if (jobs[key] === job) jobs.remove(key) }
            }
        }

        fun submitIfOwner(executor: Executor, block: (TileCancellationToken) -> V) {
            if (!isOwner) return
            try { executor.execute { runIfOwner(block) } }
            catch (failure: Throwable) {
                job.result.completeExceptionally(failure)
                synchronized(lock) { if (jobs[key] === job) jobs.remove(key) }
            }
        }

        fun await(): V {
            while (true) {
                consumer.throwIfCancelled()
                try {
                    return job.result.get(50, TimeUnit.MILLISECONDS).also {
                        consumer.throwIfCancelled()
                    }
                } catch (_: TimeoutException) {
                    // A follower can leave promptly without interrupting the owner.
                } catch (failure: ExecutionException) {
                    throw (failure.cause ?: failure)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw ProviderOperationCancelledException()
                }
            }
        }

        override fun close() {
            if (!released.compareAndSet(false, true)) return
            registration?.close()
            val stop = synchronized(lock) {
                job.consumers--
                if (job.consumers == 0 && !job.result.isDone) {
                    if (jobs[key] === job) jobs.remove(key)
                    true
                } else false
            }
            if (stop) {
                job.cancellation.cancel()
                job.result.completeExceptionally(ProviderOperationCancelledException())
            }
        }
    }

    fun acquire(key: K, consumer: TileCancellationToken): Lease {
        consumer.throwIfCancelled()
        val lease = synchronized(lock) {
            val existing = jobs[key]
            val job = existing ?: Job<V>().also { jobs[key] = it }
            job.consumers++
            Lease(key, job, existing == null, consumer)
        }
        lease.listen()
        return lease
    }

    fun cancelAll() {
        val pending = synchronized(lock) { jobs.values.toList().also { jobs.clear() } }
        pending.forEach {
            it.cancellation.cancel()
            it.result.completeExceptionally(ProviderOperationCancelledException())
        }
    }
}

/** Immutable pixel storage is never recycled while a crop can still reference it. */
internal data class SourceTilePixels(val width: Int, val height: Int, val pixels: IntArray) {
    val byteCount: Long get() = pixels.size.toLong() * Int.SIZE_BYTES
}

internal class SourcePixelCache(private val maximumBytes: Long = 8L * 1024 * 1024) {
    private val entries = LinkedHashMap<String, SourceTilePixels>(16, 0.75f, true)
    private var bytes = 0L
    @Synchronized fun get(key: String): SourceTilePixels? = entries[key]
    @Synchronized fun put(key: String, value: SourceTilePixels) {
        entries.remove(key)?.let { bytes -= it.byteCount }
        if (value.byteCount > maximumBytes) return
        entries[key] = value
        bytes += value.byteCount
        val iterator = entries.entries.iterator()
        while (bytes > maximumBytes && iterator.hasNext()) {
            bytes -= iterator.next().value.byteCount
            iterator.remove()
        }
    }
    @Synchronized fun clear() { entries.clear(); bytes = 0 }
    @Synchronized fun byteCount(): Long = bytes
}
