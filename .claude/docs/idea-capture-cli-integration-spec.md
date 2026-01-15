# Idea Capture CLI Integration Specification

**Version:** v1
**Status:** Implementation Contract
**Purpose:** Executable specification for invoking Claude Code CLI with structured output

---

## Prerequisites

### Claude Code Installation
```bash
# Verify CLI is available
which claude
# Expected: /opt/homebrew/bin/claude (or /usr/local/bin/claude)

# Test JSON output support
claude --version
# Expected: v2.x.x or higher (JSON output added in v2.0)
```

### Authentication
Claude Code uses one of:
1. **Subscription** — Authenticated via `claude login`
2. **API Key** — Environment variable `ANTHROPIC_API_KEY`

**Important:** API key takes precedence over subscription. HUD must detect which is active and warn user about billing implications.

---

## Core Integration Pattern

### Command Structure
```bash
{stdin input} | claude --print \
  --output-format json \
  --json-schema '{schema}' \
  --tools "" \
  --max-turns 1 \
  {optional flags}
```

**Flags explained:**
- `--print` — Non-interactive mode, output to stdout
- `--output-format json` — Structured output (not freeform text)
- `--json-schema '{...}'` — Validates output against schema
- `--tools ""` — Disables all built-in tools (Read, Bash, Edit, etc.)
- `--max-turns 1` — Single inference, no tool loop (cost control)

**Why stdin piping:**
- Keeps `--tools ""` working (no file access needed)
- Security: Claude only sees what we explicitly provide
- Transparency: Input is logged/auditable

---

## Use Case 1: Project Placement Validation

**When:** After user captures idea with smart default project
**Goal:** Validate assumption, suggest correction if wrong
**Cost:** ~100-200 tokens per validation

### Command

```bash
cat <<EOF | claude --print \
  --output-format json \
  --json-schema '{
    "type": "object",
    "properties": {
      "belongsHere": {"type": "boolean"},
      "suggestedProject": {"type": "string", "enum": ["project-a", "project-b", "inbox"]},
      "confidence": {"type": "number", "minimum": 0, "maximum": 1},
      "reasoning": {"type": "string"}
    },
    "required": ["belongsHere", "confidence"]
  }' \
  --tools "" \
  --max-turns 1
Context: User is browsing project "${PROJECT_NAME}" (path: ${PROJECT_PATH})

Active projects:
$(list_active_projects)  # project-a, project-b, project-c

Captured idea text:
"${IDEA_TEXT}"

Question: Does this idea belong to project "${PROJECT_NAME}"?
If not, which active project is the best match?
EOF
```

### Expected Output

```json
{
  "result": "...",
  "structured_output": {
    "belongsHere": false,
    "suggestedProject": "project-b",
    "confidence": 0.85,
    "reasoning": "Idea mentions 'authentication' which is handled in project-b"
  },
  "metadata": {
    "model": "claude-sonnet-4-5-20250929",
    "usage": {
      "input_tokens": 142,
      "output_tokens": 58
    }
  }
}
```

### Swift Parsing

```swift
struct ValidationResult: Codable {
    let belongsHere: Bool
    let suggestedProject: String?
    let confidence: Double
    let reasoning: String?
}

func validateIdeaPlacement(idea: String, currentProject: String) async throws -> ValidationResult {
    let schema = """
    {
      "type": "object",
      "properties": {
        "belongsHere": {"type": "boolean"},
        "suggestedProject": {"type": "string"},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "reasoning": {"type": "string"}
      },
      "required": ["belongsHere", "confidence"]
    }
    """

    let input = """
    Context: User is browsing project \(currentProject)

    Active projects:
    \(activeProjects.joined(separator: ", "))

    Captured idea text:
    "\(idea)"

    Question: Does this idea belong to project \(currentProject)?
    If not, which active project is the best match?
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
    process.arguments = [
        "--print",
        "--output-format", "json",
        "--json-schema", schema,
        "--tools", "",
        "--max-turns", "1"
    ]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe

    try process.run()

    // Write input
    inputPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
    try inputPipe.fileHandleForWriting.close()

    // Read output
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()

    // Parse JSON response
    struct CLIResponse: Codable {
        let structured_output: ValidationResult
        let metadata: Metadata?

        struct Metadata: Codable {
            let model: String
            let usage: Usage

            struct Usage: Codable {
                let input_tokens: Int
                let output_tokens: Int
            }
        }
    }

    let response = try JSONDecoder().decode(CLIResponse.self, from: data)
    return response.structured_output
}
```

---

## Use Case 2: Idea Enrichment (Priority/Effort)

**When:** Background after session ends (Phase 3), or manual trigger (Phase 2)
**Goal:** Assign priority, effort, tags to pending ideas
**Cost:** ~200-400 tokens per idea

### Command

```bash
cat <<EOF | claude --print \
  --output-format json \
  --json-schema '{
    "type": "object",
    "properties": {
      "priority": {"type": "string", "enum": ["p0", "p1", "p2", "p3"]},
      "effort": {"type": "string", "enum": ["small", "medium", "large", "xl"]},
      "tags": {"type": "array", "items": {"type": "string"}},
      "confidence": {"type": "number", "minimum": 0, "maximum": 1},
      "reasoning": {"type": "string"}
    },
    "required": ["priority", "effort", "confidence"]
  }' \
  --tools "" \
  --max-turns 1
Project: ${PROJECT_NAME}
Path: ${PROJECT_PATH}

Recent commits (last 3):
$(git log -3 --oneline)

Existing TODOs:
$(grep -c "TODO" **/*.{swift,rs,ts} 2>/dev/null || echo "0") items

Current idea to analyze:

### [#idea-${IDEA_ID}] ${IDEA_TITLE}
${IDEA_DESCRIPTION}

Question: Assign priority (p0=urgent, p1=important, p2=nice, p3=someday),
effort (small=<2h, medium=2-8h, large=1-2d, xl=>2d), and relevant tags.
Consider project context and recent work.
EOF
```

### Expected Output

```json
{
  "structured_output": {
    "priority": "p1",
    "effort": "medium",
    "tags": ["ux", "enhancement"],
    "confidence": 0.92,
    "reasoning": "Important UX improvement, moderate effort based on similar changes"
  },
  "metadata": {
    "model": "claude-sonnet-4-5-20250929",
    "usage": {
      "input_tokens": 287,
      "output_tokens": 72
    }
  }
}
```

### Swift Parsing

```swift
struct EnrichmentResult: Codable {
    let priority: Priority
    let effort: Effort
    let tags: [String]
    let confidence: Double
    let reasoning: String?

    enum Priority: String, Codable {
        case p0, p1, p2, p3
    }

    enum Effort: String, Codable {
        case small, medium, large, xl
    }
}

func enrichIdea(_ idea: Idea, project: Project) async throws -> EnrichmentResult {
    // Extract idea block from file
    let ideaBlock = extractIdeaBlock(ideaID: idea.id, from: project.ideasFile)

    // Get project context
    let recentCommits = try await getRecentCommits(project: project, count: 3)
    let todoCount = try await countTODOs(project: project)

    let input = """
    Project: \(project.name)
    Path: \(project.path)

    Recent commits:
    \(recentCommits.joined(separator: "\n"))

    Existing TODOs: \(todoCount) items

    Current idea to analyze:
    \(ideaBlock)

    Question: Assign priority (p0=urgent, p1=important, p2=nice, p3=someday),
    effort (small=<2h, medium=2-8h, large=1-2d, xl=>2d), and relevant tags.
    """

    let schema = """
    {
      "type": "object",
      "properties": {
        "priority": {"type": "string", "enum": ["p0","p1","p2","p3"]},
        "effort": {"type": "string", "enum": ["small","medium","large","xl"]},
        "tags": {"type": "array", "items": {"type": "string"}},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "reasoning": {"type": "string"}
      },
      "required": ["priority","effort","confidence"]
    }
    """

    let result = try await invokeClaude(input: input, schema: schema)
    return result
}
```

---

## Authentication Detection

### Test Command

```bash
claude --print --output-format json --json-schema '{
  "type": "object",
  "properties": {
    "test": {"type": "string"}
  },
  "required": ["test"]
}' --tools "" --max-turns 1 <<EOF
Output: {"test": "success"}
EOF
```

### Parse Output for Auth Method

```swift
func detectAuthMethod() async -> AuthMethod {
    // Check for API key env var
    if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil {
        return .apiKey
    }

    // Check Claude Code subscription via test invocation
    let testResult = try? await invokeClaude(input: "test", schema: "{...}")

    // Parse metadata.billing_type if available
    // (Note: This field may not exist in all CLI versions)

    return .subscription  // Default assumption if API key not set
}

enum AuthMethod {
    case apiKey
    case subscription
}
```

---

## Error Handling

### Common Errors

**1. CLI Not Found**
```
Error: claude command not found
Fix: Install Claude Code (brew install --cask claude-code)
```

**2. JSON Output Not Supported**
```
Error: Unknown option: --output-format
Fix: Update Claude Code to v2.0+
```

**3. Schema Validation Failure**
```json
{
  "error": {
    "type": "validation_error",
    "message": "Output does not match schema"
  }
}
```
HUD should: Retry with fallback prompt, or log error and skip enrichment.

**4. Rate Limit**
```json
{
  "error": {
    "type": "rate_limit_error",
    "message": "Too many requests"
  }
}
```
HUD should: Exponential backoff, or disable auto-enrichment temporarily.

**5. API Key Invalid**
```json
{
  "error": {
    "type": "authentication_error",
    "message": "Invalid API key"
  }
}
```
HUD should: Show "Test Triage" error, prompt user to fix auth.

### Swift Error Handling

```swift
enum CLIError: Error {
    case notFound
    case unsupportedVersion
    case validationError(String)
    case rateLimitError
    case authError(String)
    case timeout
}

func invokeClaude(input: String, schema: String) async throws -> StructuredOutput {
    let process = Process()
    // ... setup ...

    do {
        try process.run()

        // Set timeout (30 seconds)
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        if process.isRunning {
            process.terminate()
            throw CLIError.timeout
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let response = try JSONDecoder().decode(CLIResponse.self, from: data)

        if let error = response.error {
            switch error.type {
            case "rate_limit_error":
                throw CLIError.rateLimitError
            case "authentication_error":
                throw CLIError.authError(error.message)
            case "validation_error":
                throw CLIError.validationError(error.message)
            default:
                throw CLIError.validationError(error.message)
            }
        }

        return response.structured_output

    } catch {
        // Log error with context
        logger.error("Claude CLI invocation failed: \(error)")
        throw error
    }
}
```

---

## Hook Integration (Phase 3)

### Hook Script Location
```
~/.claude/scripts/hud-enrich-ideas.sh
```

### Hook Configuration
```json
{
  "hooks": {
    "SessionEnd": {
      "command": "~/.claude/scripts/hud-enrich-ideas.sh",
      "description": "Enrich captured ideas after session ends"
    }
  }
}
```

Stored in: `~/.claude/settings.local.json`

### Hook Script Implementation

```bash
#!/bin/bash
# ~/.claude/scripts/hud-enrich-ideas.sh
# Invoked by Claude Code SessionEnd hook

set -euo pipefail

# Prevent nested invocation
if [ "${HUD_HOOK_RUNNING:-0}" = "1" ]; then
  exit 0
fi
export HUD_HOOK_RUNNING=1

# Log to HUD debug file
LOG_FILE="$HOME/.claude/hud-hook-debug.log"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | SessionEnd hook triggered" >> "$LOG_FILE"

# Check for ideas file
IDEAS_FILE=".claude/ideas.local.md"
if [ ! -f "$IDEAS_FILE" ]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | No ideas file found, exiting" >> "$LOG_FILE"
  exit 0
fi

# Check for pending ideas
if ! grep -q "Triage: pending" "$IDEAS_FILE" 2>/dev/null; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | No pending ideas, exiting" >> "$LOG_FILE"
  exit 0
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Found pending ideas, enriching..." >> "$LOG_FILE"

# Extract pending ideas
PENDING_IDEAS=$(grep -B 1 -A 8 "Triage: pending" "$IDEAS_FILE" 2>/dev/null || echo "")

if [ -z "$PENDING_IDEAS" ]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | No pending ideas found, exiting" >> "$LOG_FILE"
  exit 0
fi

# Get project context
PROJECT_NAME=$(basename "$PWD")
RECENT_COMMITS=$(git log -3 --oneline 2>/dev/null || echo "No git history")

# Build enrichment input
INPUT=$(cat <<EOF
Project: $PROJECT_NAME
Path: $PWD

Recent commits:
$RECENT_COMMITS

Ideas to enrich:
$PENDING_IDEAS

For each idea, assign priority (p0/p1/p2/p3), effort (small/medium/large/xl), and tags.
Output JSON array with: [{id, priority, effort, tags}]
EOF
)

# Invoke Claude with hook-isolated settings (prevent re-entry)
RESULT=$(echo "$INPUT" | claude --print \
  --output-format json \
  --json-schema '{
    "type": "array",
    "items": {
      "type": "object",
      "properties": {
        "id": {"type": "string"},
        "priority": {"type": "string", "enum": ["p0","p1","p2","p3"]},
        "effort": {"type": "string", "enum": ["small","medium","large","xl"]},
        "tags": {"type": "array", "items": {"type": "string"}}
      },
      "required": ["id","priority","effort"]
    }
  }' \
  --tools "" \
  --max-turns 1 \
  --settings <(echo '{"hooks":{}}') \
  2>&1)

if [ $? -ne 0 ]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | ERROR: Claude invocation failed: $RESULT" >> "$LOG_FILE"
  exit 1
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Enrichment result: $RESULT" >> "$LOG_FILE"

# Parse JSON and update file
# (Use jq to extract structured_output array)
ENRICHMENTS=$(echo "$RESULT" | jq -r '.structured_output // .result' 2>/dev/null || echo "[]")

# Update each idea in file
# (Implementation: sed or awk to find idea by ID and update metadata)
echo "$ENRICHMENTS" | jq -c '.[]' | while read -r enrichment; do
  IDEA_ID=$(echo "$enrichment" | jq -r '.id')
  PRIORITY=$(echo "$enrichment" | jq -r '.priority')
  EFFORT=$(echo "$enrichment" | jq -r '.effort')

  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Updating idea $IDEA_ID: priority=$PRIORITY, effort=$EFFORT" >> "$LOG_FILE"

  # Update idea metadata in file
  # (Preserve ID and structure, only update Effort/Triage/Priority)
  sed -i '' -e "/\[#idea-$IDEA_ID\]/,/^---/ {
    s/- \*\*Effort:\*\* .*/- **Effort:** $EFFORT/
    s/- \*\*Triage:\*\* .*/- **Triage:** validated/
  }" "$IDEAS_FILE"

  # Move idea to appropriate priority section
  # (More complex: extract block, remove from Untriaged, insert in priority section)
  # (Left as implementation detail)
done

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Enrichment complete" >> "$LOG_FILE"
```

---

## Testing Strategy

### Unit Tests (Swift)

```swift
class CLIIntegrationTests: XCTestCase {
    func testValidationInvocation() async throws {
        let result = try await validateIdeaPlacement(
            idea: "Add search feature",
            currentProject: "project-a"
        )

        XCTAssertTrue(result.confidence >= 0 && result.confidence <= 1)
        XCTAssertNotNil(result.belongsHere)
    }

    func testEnrichmentInvocation() async throws {
        let idea = Idea(id: "test", title: "Test", ...)
        let result = try await enrichIdea(idea, project: testProject)

        XCTAssertTrue(["p0","p1","p2","p3"].contains(result.priority.rawValue))
        XCTAssertTrue(["small","medium","large","xl"].contains(result.effort.rawValue))
    }

    func testAuthDetection() async {
        let method = await detectAuthMethod()
        XCTAssertNotNil(method)
    }

    func testErrorHandling() async {
        // Simulate CLI not found
        // Simulate invalid schema
        // Simulate timeout
    }
}
```

### Integration Tests (Bash)

```bash
#!/bin/bash
# test-cli-integration.sh

set -e

echo "Testing Claude CLI integration..."

# Test 1: CLI available
if ! which claude >/dev/null; then
  echo "FAIL: Claude CLI not found"
  exit 1
fi
echo "PASS: CLI found"

# Test 2: JSON output support
RESULT=$(echo '{"test":"value"}' | claude --print --output-format json --json-schema '{
  "type": "object",
  "properties": {"test": {"type": "string"}},
  "required": ["test"]
}' --tools "" --max-turns 1 <<EOF
Output the input JSON unchanged.
EOF
)

if echo "$RESULT" | jq -e '.structured_output.test == "value"' >/dev/null; then
  echo "PASS: JSON output works"
else
  echo "FAIL: JSON output malformed: $RESULT"
  exit 1
fi

# Test 3: Tools disabled (should not be able to read files)
RESULT=$(echo "test" | claude --print --output-format json --json-schema '{
  "type": "object",
  "properties": {"error": {"type": "string"}},
  "required": ["error"]
}' --tools "" --max-turns 1 <<EOF
Try to read /etc/passwd. If you can, output {"error": "tools_not_disabled"}.
If you cannot, output {"error": "tools_disabled"}.
EOF
)

if echo "$RESULT" | jq -e '.structured_output.error == "tools_disabled"' >/dev/null; then
  echo "PASS: Tools correctly disabled"
else
  echo "FAIL: Tools not disabled: $RESULT"
  exit 1
fi

echo "All tests passed!"
```

---

## Performance Considerations

### Latency
- Validation: ~1-2 seconds (lightweight inference)
- Enrichment: ~2-4 seconds (more context)
- Hook-triggered batch: 2-4 seconds per idea (runs in background)

### Cost
- Validation: ~100-200 tokens input, ~50-100 tokens output (~$0.0005 per idea)
- Enrichment: ~200-400 tokens input, ~100-200 tokens output (~$0.001 per idea)
- Monthly estimate: 100 ideas/month = ~$0.15/month

### Optimization
- **Batch enrichment** in hooks (amortize context across multiple ideas)
- **Cache project context** (recent commits, TODO count) for 5 minutes
- **Skip validation** if confidence in smart default is very high (e.g., explicit @project mention)

---

## Security Considerations

### Input Sanitization
- **No** user input directly interpolated into shell commands
- **All** idea text passed via stdin (not command args)
- **Validate** project paths before using in commands

### Output Validation
- **Schema validation** enforced by Claude CLI (`--json-schema`)
- **Additional validation** in Swift (check enum values, ranges)
- **Never execute** content from Claude output as code

### Credential Safety
- **Never log** API keys or tokens
- **Warn** if using API key billing (env var detection)
- **Isolate** hook invocations (prevent nested loops)

---

## Debugging

### Enable Debug Logging
```bash
export HUD_CLI_DEBUG=1
```

HUD logs to: `~/.claude/hud-cli-debug.log`

### Log Format
```
2026-01-14T15:23:42Z | [CLI] Invoking validation for idea: "Add search"
2026-01-14T15:23:42Z | [CLI] Command: claude --print --output-format json ...
2026-01-14T15:23:42Z | [CLI] Input (truncated): Context: User is browsing...
2026-01-14T15:23:44Z | [CLI] Output: {"structured_output": {...}}
2026-01-14T15:23:44Z | [CLI] Parsed result: belongsHere=true, confidence=0.92
```

### Common Issues

**"Command not found: claude"**
- Check PATH includes `/opt/homebrew/bin` or `/usr/local/bin`
- Run `which claude` to locate

**"Invalid JSON schema"**
- Validate schema with online validator
- Check for unescaped quotes in schema string

**"Timeout after 30 seconds"**
- Network issue? Check `curl https://api.anthropic.com`
- Increase timeout in Swift code if needed

**"Tools still enabled"**
- Verify `--tools ""` flag (empty string, not missing)
- Test with `--tools "Read"` to confirm flag works

---

**End of CLI Integration Specification**
