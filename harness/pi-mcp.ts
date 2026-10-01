// pi extension — registers the MCP servers this run's grant names with pi's
// built-in MCP client (`-e builtin:mcp`, loaded beside this file). server.js
// sets OPILOT_MCP_SERVERS from the grant and loads both only when it names one.
//
// Every server is mcp-gw (CLAUDE.md, "MCP gateway"): it allowlists the calls,
// coerces numeric ids and trims the answers. `direct` exposure declares the
// tools like built-in ones; server.js's --tools still names each of them.
const SERVERS = {
  openproject: {
    path: "/mcp",
    description: "Live data on this OpenProject instance: work packages, projects, types, statuses. Read-only.",
  },
  github: {
    path: "/gh/mcp",
    description: "Anything public on GitHub: pull requests, issues, commits, releases, files. Read-only.",
  },
};

export default function (pi) {
  const gateway = process.env.OPILOT_MCP_GW_URL;
  if (!gateway) return;
  const headers = { Authorization: `Bearer ${process.env.OPILOT_GW_TOKEN}` };

  for (const name of (process.env.OPILOT_MCP_SERVERS || "").split(",")) {
    const server = SERVERS[name];
    if (!server) continue;
    pi.registerMcpServer(name, {
      url: `${gateway}${server.path}`, headers, exposure: "direct", timeout: 30,
      description: server.description,
    });
  }
}
