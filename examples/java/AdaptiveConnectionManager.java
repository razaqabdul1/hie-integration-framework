/*
 * AdaptiveConnectionManager.java
 * 
 * Application-level connection management with adaptive failover.
 * Part of the HIE Integration Framework.
 * 
 * Author: Abdul Razack Razack Jawahar
 * License: CC BY 4.0
 * 
 * Performance: Reduces failover time from 2-6 minutes (DNS TTL) to 10-20 seconds
 */

package com.hie.framework.failover;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

/**
 * Manages connections with automatic failover between endpoints.
 * 
 * <p>This class implements the adaptive DNS failover pattern for healthcare
 * integration systems. It maintains a list of endpoints and automatically
 * switches to backup endpoints when the primary becomes unhealthy.
 * 
 * <h3>Why Not DNS-Based Failover?</h3>
 * <p>Traditional DNS failover has significant limitations for healthcare:
 * <ul>
 *   <li>DNS TTL delays (60-300 seconds before clients see new IP)</li>
 *   <li>Persistent TCP connections don't re-resolve DNS</li>
 *   <li>Intermediate DNS caching can extend delays further</li>
 *   <li>Clinical workflows cannot tolerate 2-6 minute outages</li>
 * </ul>
 * 
 * <h3>Usage Example:</h3>
 * <pre>{@code
 * List<ServerEndpoint> endpoints = Arrays.asList(
 *     new ServerEndpoint("primary.hie.local", 61616),
 *     new ServerEndpoint("secondary.hie.local", 61616)
 * );
 * 
 * AdaptiveConnectionManager manager = new AdaptiveConnectionManager(endpoints);
 * manager.setFailoverListener(event -> {
 *     alerting.sendWarning("HIE failover: " + event);
 * });
 * manager.start();
 * 
 * // Get current active endpoint for connection
 * ServerEndpoint active = manager.getActiveEndpoint();
 * }</pre>
 */
public class AdaptiveConnectionManager {

    private static final Logger log = LoggerFactory.getLogger(AdaptiveConnectionManager.class);

    /** Default health check interval in milliseconds */
    private static final long DEFAULT_HEALTH_CHECK_INTERVAL_MS = 5000;
    
    /** Default recovery check interval (less frequent) */
    private static final long DEFAULT_RECOVERY_CHECK_INTERVAL_MS = 30000;

    private final List<ServerEndpoint> endpoints;
    private final AtomicInteger activeIndex = new AtomicInteger(0);
    private final EndpointHealthProbe healthProbe;
    private final ScheduledExecutorService scheduler;
    
    private Consumer<FailoverEvent> failoverListener;
    private Consumer<Void> connectionResetCallback;
    
    private volatile boolean running = false;
    private volatile long healthCheckIntervalMs = DEFAULT_HEALTH_CHECK_INTERVAL_MS;
    private volatile long recoveryCheckIntervalMs = DEFAULT_RECOVERY_CHECK_INTERVAL_MS;

    /**
     * Creates a connection manager with the given endpoints.
     * 
     * @param endpoints List of endpoints in priority order (first = primary)
     */
    public AdaptiveConnectionManager(List<ServerEndpoint> endpoints) {
        this(endpoints, new EndpointHealthProbe());
    }

    /**
     * Creates a connection manager with custom health probe.
     * 
     * @param endpoints   List of endpoints in priority order
     * @param healthProbe Custom health probe implementation
     */
    public AdaptiveConnectionManager(List<ServerEndpoint> endpoints, EndpointHealthProbe healthProbe) {
        if (endpoints == null || endpoints.isEmpty()) {
            throw new IllegalArgumentException("At least one endpoint is required");
        }
        this.endpoints = endpoints;
        this.healthProbe = healthProbe;
        this.scheduler = Executors.newScheduledThreadPool(2, r -> {
            Thread t = new Thread(r, "hie-failover-monitor");
            t.setDaemon(true);
            return t;
        });
    }

    /**
     * Starts the health monitoring and failover mechanism.
     */
    public synchronized void start() {
        if (running) {
            log.warn("Connection manager already running");
            return;
        }
        
        running = true;
        
        // Schedule health checks for active endpoint
        scheduler.scheduleAtFixedRate(
            this::performHealthCheck,
            healthCheckIntervalMs,
            healthCheckIntervalMs,
            TimeUnit.MILLISECONDS
        );
        
        // Schedule recovery checks for failed-over endpoints
        scheduler.scheduleAtFixedRate(
            this::checkForRecovery,
            recoveryCheckIntervalMs,
            recoveryCheckIntervalMs,
            TimeUnit.MILLISECONDS
        );
        
        log.info("Adaptive connection manager started with {} endpoints", endpoints.size());
        log.info("Primary endpoint: {}", endpoints.get(0));
    }

    /**
     * Stops the health monitoring.
     */
    public synchronized void stop() {
        running = false;
        scheduler.shutdown();
        try {
            if (!scheduler.awaitTermination(10, TimeUnit.SECONDS)) {
                scheduler.shutdownNow();
            }
        } catch (InterruptedException e) {
            scheduler.shutdownNow();
            Thread.currentThread().interrupt();
        }
        log.info("Adaptive connection manager stopped");
    }

    /**
     * Performs a health check on the active endpoint.
     */
    private void performHealthCheck() {
        if (!running) return;
        
        ServerEndpoint active = getActiveEndpoint();
        
        boolean shouldFailover = healthProbe.probeAndCheckFailover(
            active.getHost(), 
            active.getPort()
        );
        
        if (shouldFailover) {
            performFailover();
        }
    }

    /**
     * Performs failover to the next available endpoint.
     */
    private synchronized void performFailover() {
        int currentIndex = activeIndex.get();
        ServerEndpoint currentEndpoint = endpoints.get(currentIndex);
        
        // Find next healthy endpoint
        for (int i = 1; i < endpoints.size(); i++) {
            int nextIndex = (currentIndex + i) % endpoints.size();
            ServerEndpoint candidate = endpoints.get(nextIndex);
            
            // Quick probe of candidate
            if (healthProbe.probe(candidate.getHost(), candidate.getPort())) {
                activeIndex.set(nextIndex);
                
                log.warn("FAILOVER: {} -> {}", currentEndpoint, candidate);
                
                // Notify listeners
                if (failoverListener != null) {
                    FailoverEvent event = new FailoverEvent(
                        currentEndpoint, 
                        candidate, 
                        FailoverEvent.Type.FAILOVER
                    );
                    try {
                        failoverListener.accept(event);
                    } catch (Exception e) {
                        log.error("Failover listener threw exception", e);
                    }
                }
                
                // Trigger connection reset
                if (connectionResetCallback != null) {
                    try {
                        connectionResetCallback.accept(null);
                    } catch (Exception e) {
                        log.error("Connection reset callback threw exception", e);
                    }
                }
                
                // Reset probe state for new endpoint
                healthProbe.reset();
                
                return;
            }
        }
        
        log.error("FAILOVER FAILED: No healthy endpoints available!");
        
        if (failoverListener != null) {
            failoverListener.accept(new FailoverEvent(
                currentEndpoint, 
                null, 
                FailoverEvent.Type.ALL_ENDPOINTS_DOWN
            ));
        }
    }

    /**
     * Checks if the primary endpoint has recovered.
     */
    private void checkForRecovery() {
        if (!running) return;
        
        int currentIndex = activeIndex.get();
        
        // Only check for recovery if we're not on the primary
        if (currentIndex == 0) return;
        
        ServerEndpoint primary = endpoints.get(0);
        
        // Check if primary is healthy again
        if (healthProbe.probe(primary.getHost(), primary.getPort())) {
            log.info("Primary endpoint {} has recovered", primary);
            
            // Optionally: automatic failback to primary
            // For now, just log - manual failback may be preferred
            if (failoverListener != null) {
                failoverListener.accept(new FailoverEvent(
                    endpoints.get(currentIndex),
                    primary,
                    FailoverEvent.Type.PRIMARY_RECOVERED
                ));
            }
        }
    }

    /**
     * Manually triggers failback to the primary endpoint.
     * 
     * <p>Call this after confirming the primary endpoint has stabilized.
     */
    public synchronized void failbackToPrimary() {
        if (activeIndex.get() == 0) {
            log.info("Already on primary endpoint");
            return;
        }
        
        ServerEndpoint primary = endpoints.get(0);
        if (!healthProbe.probe(primary.getHost(), primary.getPort())) {
            log.warn("Cannot failback: primary endpoint {} is unhealthy", primary);
            return;
        }
        
        ServerEndpoint current = endpoints.get(activeIndex.get());
        activeIndex.set(0);
        
        log.info("FAILBACK: {} -> {} (primary)", current, primary);
        
        if (failoverListener != null) {
            failoverListener.accept(new FailoverEvent(
                current,
                primary,
                FailoverEvent.Type.FAILBACK
            ));
        }
        
        if (connectionResetCallback != null) {
            connectionResetCallback.accept(null);
        }
        
        healthProbe.reset();
    }

    /**
     * Gets the currently active endpoint.
     * 
     * @return The active endpoint
     */
    public ServerEndpoint getActiveEndpoint() {
        return endpoints.get(activeIndex.get());
    }

    /**
     * Gets the index of the active endpoint.
     * 
     * @return Index in the endpoint list (0 = primary)
     */
    public int getActiveIndex() {
        return activeIndex.get();
    }

    /**
     * Checks if currently using the primary endpoint.
     * 
     * @return true if on primary
     */
    public boolean isOnPrimary() {
        return activeIndex.get() == 0;
    }

    /**
     * Sets a listener for failover events.
     * 
     * @param listener The listener to notify on failover
     */
    public void setFailoverListener(Consumer<FailoverEvent> listener) {
        this.failoverListener = listener;
    }

    /**
     * Sets a callback to reset connections after failover.
     * 
     * <p>This callback should trigger reconnection of any pooled connections.
     * 
     * @param callback The callback to invoke
     */
    public void setConnectionResetCallback(Consumer<Void> callback) {
        this.connectionResetCallback = callback;
    }

    /**
     * Sets the health check interval.
     * 
     * @param intervalMs Interval in milliseconds
     */
    public void setHealthCheckIntervalMs(long intervalMs) {
        this.healthCheckIntervalMs = intervalMs;
    }

    /**
     * Gets health probe statistics.
     * 
     * @return Current health probe state
     */
    public HealthStatus getHealthStatus() {
        return new HealthStatus(
            getActiveEndpoint(),
            activeIndex.get(),
            healthProbe.isHealthy(),
            healthProbe.getConsecutiveFailures(),
            healthProbe.getTimeSinceLastSuccess()
        );
    }
}

/**
 * Represents a server endpoint.
 */
class ServerEndpoint {
    private final String host;
    private final int port;

    public ServerEndpoint(String host, int port) {
        this.host = host;
        this.port = port;
    }

    public String getHost() { return host; }
    public int getPort() { return port; }

    @Override
    public String toString() {
        return host + ":" + port;
    }
}

/**
 * Represents a failover event.
 */
class FailoverEvent {
    enum Type {
        FAILOVER,           // Active failover to backup
        FAILBACK,           // Manual return to primary
        PRIMARY_RECOVERED,  // Primary is healthy again
        ALL_ENDPOINTS_DOWN  // No healthy endpoints
    }

    private final ServerEndpoint from;
    private final ServerEndpoint to;
    private final Type type;
    private final long timestamp;

    public FailoverEvent(ServerEndpoint from, ServerEndpoint to, Type type) {
        this.from = from;
        this.to = to;
        this.type = type;
        this.timestamp = System.currentTimeMillis();
    }

    public ServerEndpoint getFrom() { return from; }
    public ServerEndpoint getTo() { return to; }
    public Type getType() { return type; }
    public long getTimestamp() { return timestamp; }

    @Override
    public String toString() {
        return String.format("%s: %s -> %s", type, from, to);
    }
}

/**
 * Health status for monitoring.
 */
class HealthStatus {
    private final ServerEndpoint activeEndpoint;
    private final int activeIndex;
    private final boolean healthy;
    private final int consecutiveFailures;
    private final long timeSinceLastSuccessMs;

    public HealthStatus(ServerEndpoint activeEndpoint, int activeIndex, 
                        boolean healthy, int consecutiveFailures, 
                        long timeSinceLastSuccessMs) {
        this.activeEndpoint = activeEndpoint;
        this.activeIndex = activeIndex;
        this.healthy = healthy;
        this.consecutiveFailures = consecutiveFailures;
        this.timeSinceLastSuccessMs = timeSinceLastSuccessMs;
    }

    // Getters omitted for brevity
}
