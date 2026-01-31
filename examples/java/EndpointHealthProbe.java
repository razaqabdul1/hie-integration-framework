/*
 * EndpointHealthProbe.java
 * 
 * Application-level health probing for adaptive DNS failover.
 * Part of the HIE Integration Framework.
 * 
 * Author: Abdul Razack Razack Jawahar
 * License: CC BY 4.0
 * 
 * Performance: Reduces failover time from 2-6 minutes to 10-20 seconds
 */

package com.hie.framework.failover;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Performs lightweight health probes on integration endpoints.
 * 
 * <p>This class implements the health probing component of the adaptive DNS
 * failover mechanism. Unlike traditional DNS-based failover that relies on
 * TTL expiration, this approach enables detection of endpoint failures within
 * seconds.
 * 
 * <h3>Key Features:</h3>
 * <ul>
 *   <li>Socket-level connectivity verification</li>
 *   <li>Optional application-level health check (PING/PONG)</li>
 *   <li>Consecutive failure counting to avoid false positives</li>
 *   <li>Configurable timeouts and thresholds</li>
 * </ul>
 * 
 * <h3>Usage Example:</h3>
 * <pre>{@code
 * EndpointHealthProbe probe = new EndpointHealthProbe();
 * 
 * // Check if endpoint should be marked as unhealthy
 * boolean shouldFailover = probe.probeAndCheckFailover("primary.hie.local", 61616);
 * 
 * if (shouldFailover) {
 *     connectionManager.failoverToBackup();
 * }
 * }</pre>
 * 
 * <h3>Integration with Scheduled Health Checks:</h3>
 * <pre>{@code
 * @Scheduled(fixedRate = 5000) // Every 5 seconds
 * public void healthCheckLoop() {
 *     if (probe.probeAndCheckFailover(primaryHost, primaryPort)) {
 *         log.warn("Primary endpoint unhealthy, initiating failover");
 *         connectionManager.failover();
 *     }
 * }
 * }</pre>
 */
public class EndpointHealthProbe {

    private static final Logger log = LoggerFactory.getLogger(EndpointHealthProbe.class);

    /** Connection timeout in milliseconds */
    private final int connectionTimeoutMs;
    
    /** Read timeout for health check response */
    private final int readTimeoutMs;
    
    /** Number of consecutive failures before marking unhealthy */
    private final int failureThreshold;
    
    /** Whether to perform application-level health check */
    private final boolean useApplicationCheck;
    
    /** Counter for consecutive probe failures */
    private final AtomicInteger consecutiveFailures = new AtomicInteger(0);
    
    /** Timestamp of last successful probe */
    private volatile long lastSuccessTimestamp = System.currentTimeMillis();

    /**
     * Creates a health probe with default settings.
     * 
     * <p>Defaults:
     * <ul>
     *   <li>Connection timeout: 3000ms</li>
     *   <li>Read timeout: 2000ms</li>
     *   <li>Failure threshold: 3 consecutive failures</li>
     *   <li>Application check: enabled</li>
     * </ul>
     */
    public EndpointHealthProbe() {
        this(3000, 2000, 3, true);
    }

    /**
     * Creates a health probe with custom settings.
     * 
     * @param connectionTimeoutMs Connection timeout in milliseconds
     * @param readTimeoutMs       Read timeout in milliseconds
     * @param failureThreshold    Consecutive failures before unhealthy
     * @param useApplicationCheck Whether to use PING/PONG check
     */
    public EndpointHealthProbe(int connectionTimeoutMs, int readTimeoutMs, 
                                int failureThreshold, boolean useApplicationCheck) {
        this.connectionTimeoutMs = connectionTimeoutMs;
        this.readTimeoutMs = readTimeoutMs;
        this.failureThreshold = failureThreshold;
        this.useApplicationCheck = useApplicationCheck;
    }

    /**
     * Probes an endpoint and returns whether failover should be triggered.
     * 
     * @param host The hostname to probe
     * @param port The port to probe
     * @return true if failover should be triggered (threshold exceeded)
     */
    public boolean probeAndCheckFailover(String host, int port) {
        boolean healthy = probe(host, port);
        
        if (healthy) {
            int previousFailures = consecutiveFailures.getAndSet(0);
            lastSuccessTimestamp = System.currentTimeMillis();
            
            if (previousFailures > 0) {
                log.info("Endpoint {}:{} recovered after {} failures", 
                         host, port, previousFailures);
            }
            return false;
        }
        
        int failures = consecutiveFailures.incrementAndGet();
        log.warn("Endpoint {}:{} probe failed. Consecutive failures: {}/{}", 
                 host, port, failures, failureThreshold);
        
        return failures >= failureThreshold;
    }

    /**
     * Performs a single health probe on the endpoint.
     * 
     * @param host The hostname to probe
     * @param port The port to probe
     * @return true if the endpoint is healthy
     */
    public boolean probe(String host, int port) {
        long startTime = System.currentTimeMillis();
        
        try (Socket socket = new Socket()) {
            // Step 1: TCP connection check
            socket.connect(new InetSocketAddress(host, port), connectionTimeoutMs);
            socket.setSoTimeout(readTimeoutMs);
            
            long connectTime = System.currentTimeMillis() - startTime;
            log.trace("TCP connect to {}:{} succeeded in {}ms", host, port, connectTime);
            
            // Step 2: Optional application-level check
            if (useApplicationCheck) {
                return performApplicationCheck(socket, host, port);
            }
            
            return true;
            
        } catch (IOException e) {
            long elapsed = System.currentTimeMillis() - startTime;
            log.debug("Probe failed for {}:{} after {}ms - {}", 
                      host, port, elapsed, e.getMessage());
            return false;
        }
    }

    /**
     * Performs application-level health check using PING/PONG protocol.
     * 
     * <p>This provides deeper health verification than TCP connectivity alone.
     * The endpoint must respond to "PING\r\n" with "PONG" to be considered healthy.
     */
    private boolean performApplicationCheck(Socket socket, String host, int port) {
        try {
            OutputStream out = socket.getOutputStream();
            InputStream in = socket.getInputStream();
            
            // Send PING
            out.write("PING\r\n".getBytes());
            out.flush();
            
            // Read response
            byte[] response = new byte[4];
            int bytesRead = in.read(response, 0, 4);
            
            if (bytesRead >= 4) {
                String responseStr = new String(response, 0, 4);
                if (responseStr.equals("PONG")) {
                    log.trace("Application check passed for {}:{}", host, port);
                    return true;
                }
                log.debug("Unexpected response from {}:{}: {}", host, port, responseStr);
            } else {
                log.debug("Incomplete response from {}:{}: {} bytes", host, port, bytesRead);
            }
            
            return false;
            
        } catch (IOException e) {
            log.debug("Application check failed for {}:{} - {}", host, port, e.getMessage());
            return false;
        }
    }

    /**
     * Resets the failure counter.
     * 
     * <p>Call this after a successful manual recovery or when switching
     * back to a recovered primary endpoint.
     */
    public void reset() {
        consecutiveFailures.set(0);
        lastSuccessTimestamp = System.currentTimeMillis();
        log.info("Health probe state reset");
    }

    /**
     * Gets the current consecutive failure count.
     * 
     * @return Number of consecutive probe failures
     */
    public int getConsecutiveFailures() {
        return consecutiveFailures.get();
    }

    /**
     * Gets the timestamp of the last successful probe.
     * 
     * @return Timestamp in milliseconds since epoch
     */
    public long getLastSuccessTimestamp() {
        return lastSuccessTimestamp;
    }

    /**
     * Gets the configured failure threshold.
     * 
     * @return Number of failures before triggering failover
     */
    public int getFailureThreshold() {
        return failureThreshold;
    }

    /**
     * Checks if the endpoint is currently considered healthy.
     * 
     * @return true if consecutive failures are below threshold
     */
    public boolean isHealthy() {
        return consecutiveFailures.get() < failureThreshold;
    }

    /**
     * Gets the time since last successful probe in milliseconds.
     * 
     * @return Milliseconds since last success
     */
    public long getTimeSinceLastSuccess() {
        return System.currentTimeMillis() - lastSuccessTimestamp;
    }
}
