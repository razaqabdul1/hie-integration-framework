# HIE Integration Framework - Quick Reference Guide

## Pattern Selection Matrix

| Problem | Pattern | Key Benefit |
|---------|---------|-------------|
| Database write contention in active-active | Schema Partitioning | Zero contention, 3x throughput |
| Audit logging impacts performance | Async Audit + Reconciliation | 10-30x latency reduction |
| Slow first request after restart | Eager Initialization | 40x first-request improvement |
| Mixed internal/external traffic | Dual Security Boundaries | Simplified security management |
| Storage costs growing | Time-Based Archival | 80-95% cost reduction |
| DNS failover too slow | Adaptive Failover | 90%+ faster recovery |

## Performance Targets

| Metric | Target | Warning | Critical |
|--------|--------|---------|----------|
| Message latency (P50) | < 25ms | 25-50ms | > 50ms |
| Message latency (P99) | < 250ms | 250-500ms | > 500ms |
| Audit pending queue | < 100 | 100-500 | > 500 |
| Dead letter queue | < 10 | 10-50 | > 50 |
| Failover time | < 30s | 30-60s | > 60s |

## Common HL7v2 Message Types

| Message | Trigger | Description |
|---------|---------|-------------|
| ADT^A01 | Admit | Patient admitted |
| ADT^A02 | Transfer | Patient transferred |
| ADT^A03 | Discharge | Patient discharged |
| ADT^A08 | Update | Demographics updated |
| ORM^O01 | Order | New order placed |
| ORU^R01 | Result | Result reported |
| MDM^T02 | Document | Document notification |

## Implementation Checklist

### Architecture
- [ ] Layer separation defined
- [ ] HA strategy implemented
- [ ] Schema partitioning configured
- [ ] Failover tested

### Security
- [ ] TLS 1.2+ enforced
- [ ] Certificate management established
- [ ] Dual boundaries implemented
- [ ] Audit logging captures all PHI access

### Compliance
- [ ] HIPAA audit requirements met
- [ ] 7-year retention policy implemented
- [ ] Consent enforcement configured

### Performance
- [ ] Eager initialization enabled
- [ ] Connection pools optimized
- [ ] Async audit with reconciliation
- [ ] Monitoring dashboards deployed

## Code Snippets

### Async Audit (Java)
```java
String correlationId = UUID.randomUUID().toString();
minimalAuditRepo.save(correlationId, "PENDING");  // ~5ms
auditQueue.publish(new AuditPayload(correlationId, msg));  // ~2ms
```

### Health Probe (Java)
```java
try (Socket socket = new Socket()) {
    socket.connect(new InetSocketAddress(host, port), 3000);
    return true;
} catch (IOException e) {
    return false;
}
```

### Schema Partitioning (SQL)
```sql
CREATE VIEW v_all_audit_logs AS
    SELECT 'node1', * FROM app_node1.audit_log
    UNION ALL
    SELECT 'node2', * FROM app_node2.audit_log;
```

## Key References

- [TEFCA Common Agreement v2.1](https://rce.sequoiaproject.org/)
- [HL7 FHIR R4](https://www.hl7.org/fhir/)
- [HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/)
- [IHE IT Infrastructure](https://www.ihe.net/resources/technical_frameworks/#IT)

---

*For full details, see the complete technical framework document.*
