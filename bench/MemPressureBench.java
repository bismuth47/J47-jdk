import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;

/**
 * MemPressureBench - J47 (Generational ZGC)向けメモリ高負荷ベンチ.
 * 依存なし (javacのみでビルド可)。JMHなしで allocation / promotion 圧を再現する。
 *
 * 動作:
 *  - Nスレッドが durationSec の間ループ:
 *    - short-lived: byte[allocKB*1024] を確保→fill→checksum (Young GC圧)
 *    - 10%を longLivedList に保持 (上限付き, Tenured/Old昇格圧)
 *    - 1%で大きな配列 (largeKB) を確保 (humongous的スパイク)
 *  - 反復ごとに nanoTimeでレイテンシ計測し、スレッドローカル配列に記録
 *    (最大 maxSamples件まで。超えた分はカウンタのみ)。
 *
 * 使い方:
 *   javac bench/MemPressureBench.java
 *   java -Xms4G -Xmx4G -XX:+UseZGC -XX:+ZGenerational ... \
 *     -cp bench MemPressureBench --threads 8 --duration 60 --alloc-kb 64 --large-kb 4096
 */
public class MemPressureBench {
    static class Config {
        int threads = Runtime.getRuntime().availableProcessors();
        int durationSec = 60;
        int allocKB = 64;
        int largeKB = 4096;
        int liveCapMB = 512;
        int maxSamples = 200000;
    }

    static class Worker implements Runnable {
        final Config cfg;
        final CountDownLatch startGate;
        final AtomicLong ops;
        final AtomicLong bytes;
        final AtomicLong checksum;
        final long[] samples;
        int sampleCount = 0;
        long sampleOverflow = 0;
        final List<byte[]> live = new ArrayList<>();
        long liveBytes = 0;

        Worker(Config cfg, CountDownLatch g, AtomicLong ops, AtomicLong bytes, AtomicLong cs) {
            this.cfg = cfg;
            this.startGate = g;
            this.ops = ops;
            this.bytes = bytes;
            this.checksum = cs;
            this.samples = new long[cfg.maxSamples];
        }

        @Override
        public void run() {
            try { startGate.await(); } catch (InterruptedException e) { return; }
            ThreadLocalRandom rnd = ThreadLocalRandom.current();
            long end = System.nanoTime() + (long) cfg.durationSec * 1_000_000_000L;
            byte[] buf = null;
            while (System.nanoTime() < end) {
                long t0 = System.nanoTime();
                // 1% large spike, else normal alloc
                int kb = (rnd.nextInt(100) == 0) ? cfg.largeKB : cfg.allocKB;
                buf = new byte[kb * 1024];
                // fill + checksum (最適化で消されないよう累積)
                long sum = 0;
                byte v = (byte) rnd.nextInt();
                Arrays.fill(buf, v);
                for (int i = 0; i < buf.length; i += 4096) sum += buf[i];
                checksum.addAndGet(sum + buf.length);

                // 10%を保持 (Tenured昇格用)。上限超過で半分捨てる
                if (rnd.nextInt(10) == 0) {
                    live.add(buf);
                    liveBytes += buf.length;
                    long cap = (long) cfg.liveCapMB * 1024 * 1024;
                    if (liveBytes > cap) {
                        int drop = live.size() / 2;
                        for (int i = 0; i < drop; i++) {
                            liveBytes -= live.remove(0).length;
                        }
                    }
                }
                long dt = System.nanoTime() - t0;
                if (sampleCount < samples.length) samples[sampleCount++] = dt;
                else sampleOverflow++;
                ops.incrementAndGet();
                bytes.addAndGet(buf.length);
            }
        }
    }

    public static void main(String[] args) throws Exception {
        Config cfg = new Config();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--threads": cfg.threads = Integer.parseInt(args[++i]); break;
                case "--duration": cfg.durationSec = Integer.parseInt(args[++i]); break;
                case "--alloc-kb": cfg.allocKB = Integer.parseInt(args[++i]); break;
                case "--large-kb": cfg.largeKB = Integer.parseInt(args[++i]); break;
                case "--live-mb": cfg.liveCapMB = Integer.parseInt(args[++i]); break;
                case "--max-samples": cfg.maxSamples = Integer.parseInt(args[++i]); break;
                case "--help":
                    System.out.println("usage: MemPressureBench [--threads N] [--duration SEC] [--alloc-kb KB] [--large-kb KB] [--live-mb MB]");
                    return;
                default: System.err.println("unknown arg: " + args[i]); System.exit(2);
            }
        }
        System.out.printf("MemPressureBench threads=%d duration=%ds alloc=%dKB large=%dKB liveCap=%dMB%n",
                cfg.threads, cfg.durationSec, cfg.allocKB, cfg.largeKB, cfg.liveCapMB);
        System.out.printf("java=%s %s | cpus=%d | heap max=%.1fGB%n",
                System.getProperty("java.version"), System.getProperty("java.vm.name"),
                Runtime.getRuntime().availableProcessors(),
                Runtime.getRuntime().maxMemory() / 1e9);

        CountDownLatch gate = new CountDownLatch(1);
        AtomicLong ops = new AtomicLong();
        AtomicLong bytes = new AtomicLong();
        AtomicLong checksum = new AtomicLong();
        List<Worker> workers = new ArrayList<>();
        List<Thread> threads = new ArrayList<>();
        for (int i = 0; i < cfg.threads; i++) {
            Worker w = new Worker(cfg, gate, ops, bytes, checksum);
            workers.add(w);
            Thread t = new Thread(w, "bench-worker-" + i);
            threads.add(t);
            t.start();
        }
        // ウォームアップ表示なしで一斉開始
        long wall0 = System.nanoTime();
        gate.countDown();
        for (Thread t : threads) t.join();
        double wallSec = (System.nanoTime() - wall0) / 1e9;

        long totalOps = ops.get();
        double gb = bytes.get() / 1e9;
        System.out.printf("RESULT ops=%d elapsed=%.1fs throughput=%.0f ops/s allocRate=%.2f GB/s (%.1f GB total) checksum=%d%n",
                totalOps, wallSec, totalOps / wallSec, gb / wallSec, gb, checksum.get());

        // レイテンシ集計 (全ワーカーのサンプルを結合)
        long totalSamples = 0;
        long overflow = 0;
        for (Worker w : workers) { totalSamples += w.sampleCount; overflow += w.sampleOverflow; }
        if (totalSamples == 0) { System.out.println("no samples"); return; }
        long[] all = new long[(int) Math.min(totalSamples, Integer.MAX_VALUE)];
        int pos = 0;
        for (Worker w : workers) {
            System.arraycopy(w.samples, 0, all, pos, w.sampleCount);
            pos += w.sampleCount;
        }
        Arrays.sort(all);
        double avg = 0;
        long max = all[all.length - 1];
        for (long v : all) avg += (double) v / all.length;
        // ns -> us 表示
        System.out.printf("LATENCY(ns->us) samples=%d overflow=%d avg=%.1fus p50=%.1fus p90=%.1fus p99=%.1fus p99.9=%.1fus max=%.1fus%n",
                totalSamples, overflow,
                avg / 1000.0,
                all[(int) (all.length * 0.50)] / 1000.0,
                all[(int) (all.length * 0.90)] / 1000.0,
                all[(int) (all.length * 0.99)] / 1000.0,
                all[(int) (all.length * 0.999)] / 1000.0,
                max / 1000.0);
        System.out.println("BENCH DONE");
    }
}
