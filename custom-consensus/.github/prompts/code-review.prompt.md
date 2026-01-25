---
description: Review code for blockchain-specific issues and best practices
---

# Blockchain Code Review Prompt

Review the code for the following:

## Byzantine Fault Tolerance

- [ ] Is the BFT threshold calculation correct? `Math.floor(2 * N / 3) + 1`
- [ ] Are there proper checks for faulty node behavior?
- [ ] Is consensus safety maintained in all code paths?

## Transaction Processing

- [ ] Is transaction validation thorough?
- [ ] Are transactions properly batched before block creation?
- [ ] Is the transaction threshold respected (no bypass logic)?
- [ ] Are duplicate transactions prevented?

## Network Communication

- [ ] Are WebSocket errors handled with retry logic?
- [ ] Is the IDA gossip protocol used correctly for message distribution?
- [ ] Are messages validated before processing?
- [ ] Is proper logging in place for network events?

## Code Quality

- [ ] Are magic numbers extracted to constants?
- [ ] Is console.log replaced with logger utility?
- [ ] Are methods under 50 lines?
- [ ] Are there JSDoc comments on public methods?
- [ ] Are early returns used instead of deep nesting?

## Blockchain Correctness

- [ ] Is block creation only triggered by proposer?
- [ ] Are all PBFT phases implemented correctly?
- [ ] Is the chain validity checked before adding blocks?
- [ ] Are pools cleared after successful block commit?

## Security

- [ ] Are all inputs validated?
- [ ] Is cryptographic signature verification present?
- [ ] Are there checks against Byzantine attacks?
- [ ] Is sensitive data properly handled?

Provide specific feedback on any issues found with code examples.
