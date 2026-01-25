# GitHub Copilot Instructions Setup

This directory contains custom instructions, prompts, and agents to enhance GitHub Copilot's understanding of this blockchain project.

## Structure

```
.github/
├── instructions/          # Context-specific instructions
│   ├── blockchain-pbft.instructions.md     # PBFT blockchain specifics
│   └── javascript.instructions.md           # JavaScript/Node.js standards
├── prompts/               # Reusable task prompts
│   └── code-review.prompt.md               # Code review checklist
└── agents/                # Custom AI agents
    └── blockchain-architect.agent.md       # System design agent
```

## Files Explanation

### Instructions (`*.instructions.md`)

Instructions provide Copilot with repository-specific context:

- **blockchain-pbft.instructions.md** - Core blockchain concepts, PBFT consensus, RapidChain sharding, code patterns, and common pitfalls
- **javascript.instructions.md** - JavaScript/Node.js coding standards, naming conventions, and best practices

Copilot automatically uses these when editing matching files.

### Prompts (`*.prompt.md`)

Prompts are reusable templates for specific tasks:

- **code-review.prompt.md** - Comprehensive checklist for reviewing blockchain code

**Usage:** Reference in Copilot Chat: `@workspace /review using #file:code-review.prompt.md`

### Agents (`*.agent.md`)

Custom AI personas for specific roles:

- **blockchain-architect.agent.md** - System design and architecture planning

**Usage:** Switch to agent mode in VS Code Copilot Chat

## How to Use

### 1. Instructions (Automatic)

Instructions apply automatically when editing matching files. The `applyTo` field in the YAML front matter specifies which files trigger each instruction.

### 2. Prompts (Manual Reference)

In Copilot Chat:
```
@workspace Use #file:code-review.prompt.md to review the changes in p2pserver.js
```

### 3. Agents (Agent Mode)

1. Open Copilot Chat
2. Type `@` and select your custom agent
3. Or reference in chat: `@blockchain-architect How should I design cross-shard communication?`

## Adding More Instructions

### From awesome-copilot-agents Repository

Visit https://github.com/Code-and-Sorts/awesome-copilot-agents for more:

**Relevant for this project:**
- `instructions/languages/javascript/` - JavaScript best practices
- `instructions/workflows/ai-development-instructions/` - Development workflows
- `agents/ai-development-mode/debugger.agent.md` - Debugging agent
- `agents/ai-development-mode/clean-code.agent.md` - Code quality agent

### Custom Instructions

Create new `.instructions.md` files with YAML front matter:

```markdown
---
applyTo:
  - "**/*.js"
description: Your description here
---

# Your Instructions

Content here...
```

## Tips

1. **Be Specific**: More context = better suggestions
2. **Keep Updated**: Update instructions as the project evolves
3. **Use Examples**: Include code examples in instructions
4. **Test Prompts**: Iterate on prompt wording for better results
5. **Layer Instructions**: Use multiple instruction files for different concerns

## VS Code Setup

Ensure you have:
- GitHub Copilot extension installed
- Signed in to GitHub
- Copilot enabled in settings

VS Code automatically discovers files in `.github/`:
- `.github/instructions/*.instructions.md`
- `.github/prompts/*.prompt.md`
- `.github/agents/*.agent.md`

## Examples

### Ask for Architecture Review
```
@blockchain-architect Review the current p2pserver.js implementation for Byzantine fault tolerance
```

### Use Code Review Prompt
```
@workspace Review pbft-rapidchain/services/blockchain.js using #file:code-review.prompt.md
```

### Reference Instructions
Copilot automatically uses blockchain-pbft.instructions.md when you ask about:
- "How should I implement PBFT consensus?"
- "What's the correct BFT threshold calculation?"
- "How does IDA gossip work in this project?"

## Contributing

To add new instructions:
1. Create new `.instructions.md`, `.prompt.md`, or `.agent.md` file
2. Follow the YAML front matter format
3. Be specific and include examples
4. Test with Copilot to ensure it works as expected

## References

- [VS Code Copilot Documentation](https://code.visualstudio.com/docs/copilot/copilot-customization)
- [Awesome Copilot Agents](https://github.com/Code-and-Sorts/awesome-copilot-agents)
- [Agent Skills Standard](https://agentskills.io/home)
