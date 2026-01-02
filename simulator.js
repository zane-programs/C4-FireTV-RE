const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

const hostname = "0.0.0.0";

// Load self-signed certificate for HTTPS
const httpsOptions = {
  key: fs.readFileSync(path.join(__dirname, "key.pem")),
  cert: fs.readFileSync(path.join(__dirname, "cert.pem")),
};

// Shared request handler
function requestHandler(req, res) {
  console.log(`\n${req.method} ${req.url}`);
  console.log(req.headers);

  req.on("data", chunk => {
    console.log("BODY: " + chunk);
  });

  res.statusCode = req.method === "PUT" ? 201 : 200;
  res.setHeader("Content-Type", "text/plain");
  res.end("Hello World\n");
}

// HTTP server on port 8009
const httpServer = http.createServer(requestHandler);
httpServer.listen(8009, hostname, () => {
  console.log(`HTTP server running at http://localhost:8009/`);
});

// HTTPS server on port 8080
const httpsServer = https.createServer(httpsOptions, requestHandler);
httpsServer.listen(8080, hostname, () => {
  console.log(`HTTPS server running at https://localhost:8080/`);
});
