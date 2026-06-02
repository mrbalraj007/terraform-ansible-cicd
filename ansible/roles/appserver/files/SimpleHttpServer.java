/**
 * SimpleHttpServer.java
 *
 * A minimal HTTP server using the JDK built-in com.sun.net.httpserver.
 * Responds on port APP_PORT (default 8080) with host info in JSON.
 *
 * Compiled on the target EC2 instance by Ansible after java-17-corretto is installed.
 */

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpExchange;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

public class SimpleHttpServer {

    private static final int PORT = Integer.parseInt(System.getenv().getOrDefault("APP_PORT", "8080"));

    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(PORT), 0);
        server.createContext("/", SimpleHttpServer::handleRoot);
        server.createContext("/health", SimpleHttpServer::handleHealth);
        server.setExecutor(null); // uses the default executor

        System.out.println("SimpleHttpServer started on port " + PORT);
        server.start();
    }

    private static void handleRoot(HttpExchange exchange) throws IOException {
        String hostname = getHostname();
        String localIp = getLocalIp();
        String now = LocalDateTime.now().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME);

        String json = String.format("""
                {
                  "status": "ok",
                  "app": "SimpleHttpServer",
                  "hostname": "%s",
                  "localIp": "%s",
                  "timestamp": "%s"
                }
                """, escape(hostname), escape(localIp), escape(now));

        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static void handleHealth(HttpExchange exchange) throws IOException {
        String json = "{\"status\":\"healthy\"}";
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static String getHostname() {
        try {
            java.net.InetAddress addr = java.net.InetAddress.getLocalHost();
            return addr.getHostName();
        } catch (Exception e) {
            return "unknown";
        }
    }

    private static String getLocalIp() {
        try {
            java.net.InetAddress addr = java.net.InetAddress.getLocalHost();
            return addr.getHostAddress();
        } catch (Exception e) {
            return "0.0.0.0";
        }
    }

    private static String escape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}