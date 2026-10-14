/**
 * Google Search Console OAuth2 Authentication Flow
 *
 * Opens a browser for Google OAuth2 consent, then exchanges the auth code
 * for a refresh token that can be used by the Search Console tools.
 *
 * Usage:
 *   cd "$AGENT_INFRA_PATH/mcp-servers/seo-intelligence" && npm run auth:search-console
 *
 * Prerequisites:
 *   - Create .env in mcp-servers/seo-intelligence/ (copy .env.example) with
 *     GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET
 */
import { google } from "googleapis";
import http from "node:http";
import { URL } from "node:url";
import { config } from "dotenv";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
config({ path: resolve(__dirname, "../.env") });

const CLIENT_ID = process.env.GOOGLE_CLIENT_ID;
const CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET;

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error("ERROR: GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET must be set in mcp-servers/seo-intelligence/.env (copied from .env.example)");
  process.exit(1);
}

const REDIRECT_PORT = 3457;
const REDIRECT_URI = `http://localhost:${REDIRECT_PORT}/callback`;

const oauth2Client = new google.auth.OAuth2(CLIENT_ID, CLIENT_SECRET, REDIRECT_URI);

const SCOPES = ["https://www.googleapis.com/auth/webmasters.readonly"];

async function main() {
  const authUrl = oauth2Client.generateAuthUrl({
    access_type: "offline",
    scope: SCOPES,
    prompt: "consent",
  });

  console.log("\n=== Google Search Console OAuth2 Authentication ===\n");
  console.log("Opening browser for authentication...\n");
  console.log("If the browser doesn't open, visit this URL:\n");
  console.log(authUrl);
  console.log("");

  try {
    const open = (await import("open")).default;
    await open(authUrl);
  } catch {
    console.log("(Could not open browser automatically — please visit the URL above)");
  }

  const code = await new Promise<string>((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      try {
        const url = new URL(req.url!, `http://localhost:${REDIRECT_PORT}`);
        const authCode = url.searchParams.get("code");

        if (url.pathname === "/callback" && authCode) {
          res.writeHead(200, { "Content-Type": "text/html" });
          res.end("<h1>Authentication successful!</h1><p>You can close this window.</p>");
          server.close();
          resolve(authCode);
        } else {
          res.writeHead(400, { "Content-Type": "text/plain" });
          res.end("No auth code received");
        }
      } catch (err) {
        res.writeHead(500);
        res.end("Error");
        reject(err);
      }
    });

    server.listen(REDIRECT_PORT, () => {
      console.log(`Waiting for callback on port ${REDIRECT_PORT}...`);
    });

    setTimeout(() => {
      server.close();
      reject(new Error("Timed out waiting for authentication"));
    }, 5 * 60 * 1000);
  });

  console.log("\nReceived auth code, exchanging for tokens...");
  const { tokens } = await oauth2Client.getToken(code);
  console.log("\n=== Tokens ===");
  console.log(`Refresh token: ${tokens.refresh_token}`);
  console.log(`\nAdd to mcp-servers/seo-intelligence/.env:`);
  console.log(`GOOGLE_REFRESH_TOKEN=${tokens.refresh_token}`);
}

main().catch(console.error);
