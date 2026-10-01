// pi extension — registers this run's MCP servers with pi's built-in client
// (`-e builtin:mcp`, loaded beside it) and trims their answers. server.js loads
// both only for a grant that names a server, and passes the configs (all on
// mcp-gw, CLAUDE.md "MCP gateway") in OPILOT_MCP_SERVERS.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const { shapeCallResult } = require("./mcp-shape.js");

export default function (pi) {
  for (const { name, config } of JSON.parse(process.env.OPILOT_MCP_SERVERS || "[]")) {
    pi.registerMcpServer(name, config);
  }

  // pi's MCP tools put the whole, untruncated CallToolResult in
  // structuredContent and { server, tool } in details. Replacing content alone
  // would drop structuredContent, so the trimmed copy goes there too.
  pi.on("tool_result", (event) => {
    const { server, tool } = event.details || {};
    if (!server || !tool) return undefined;
    const content = shapeCallResult(server, tool, event.structuredContent);
    if (!content) return undefined;
    return { content, structuredContent: { content, isError: event.isError } };
  });
}
