{
  "mcpServers": {
    "jcodemunch-mcp": {
      "command": "python3",
      "args": ["-m", "jcodemunch_mcp"],
      "env": {
        "JCODEMUNCH_HOME": "__PLEIADES_ROOT__/tools/jcodemunch-mcp",
        "JCODEMUNCH_API_PORT": "37700"
      },
      "disabled": false,
      "autoApprove": []
    },
    "fastapi-mcp": {
      "command": "python3",
      "args": ["-m", "fastapi_mcp"],
      "disabled": true,
      "autoApprove": []
    },
    "openapi-mcp-codegen": {
      "command": "python3",
      "args": ["-m", "openapi_mcp_codegen"],
      "disabled": true,
      "autoApprove": []
    },
    "piia-engram": {
      "command": "python3",
      "args": ["-m", "piia_engram.mcp_server"],
      "disabled": true,
      "autoApprove": []
    },
    "files-sdk": {
      "command": "node",
      "args": ["index.js"],
      "disabled": true,
      "autoApprove": []
    }
  }
}
