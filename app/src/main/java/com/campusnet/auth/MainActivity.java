package com.campusnet.auth;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.net.wifi.WifiNetworkSpecifier;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

public class MainActivity extends AppCompatActivity {

    private EditText etPortal, etSsid, etUser, etPass, etService, etUpdateUrl;
    private Spinner spBand;
    private Button btnSave, btnAuth, btnConnect, btnCheckUpdate;
    private TextView tvLog;
    private ScrollView svLog;

    private SharedPreferences sp;
    private WifiManager wifiManager;
    private static final int PERM_REQ = 1001;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        etPortal = findViewById(R.id.etPortal);
        etSsid = findViewById(R.id.etSsid);
        etUser = findViewById(R.id.etUser);
        etPass = findViewById(R.id.etPass);
        etService = findViewById(R.id.etService);
        etUpdateUrl = findViewById(R.id.etUpdateUrl);
        spBand = findViewById(R.id.spBand);
        btnSave = findViewById(R.id.btnSave);
        btnAuth = findViewById(R.id.btnAuth);
        btnConnect = findViewById(R.id.btnConnect);
        btnCheckUpdate = findViewById(R.id.btnCheckUpdate);
        tvLog = findViewById(R.id.tvLog);
        svLog = findViewById(R.id.svLog);

        sp = getSharedPreferences("campus_config", Context.MODE_PRIVATE);
        wifiManager = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);

        loadConfig();
        requestPermissions();

        btnSave.setOnClickListener(v -> {
            saveConfig();
            appendLog("配置已保存");
            Toast.makeText(this, "配置已保存", Toast.LENGTH_SHORT).show();
        });

        btnConnect.setOnClickListener(v -> {
            saveConfig();
            appendLog("===== 开始连接WiFi =====");
            new Thread(this::connectWifi).start();
        });

        btnAuth.setOnClickListener(v -> {
            saveConfig();
            appendLog("===== 开始认证 =====");
            new Thread(this::doAuth).start();
        });

        btnCheckUpdate.setOnClickListener(v -> {
            saveConfig();
            new Thread(this::checkUpdate).start();
        });
    }

    private void loadConfig() {
        etPortal.setText(sp.getString("portalUrl", "http://10.10.1.188"));
        etSsid.setText(sp.getString("ssid", "CQRK"));
        etUser.setText(sp.getString("username", ""));
        etPass.setText(sp.getString("password", ""));
        etService.setText(sp.getString("service", "中国移动"));
        etUpdateUrl.setText(sp.getString("updateUrl", ""));
        int bandIdx = sp.getInt("bandPref", 1); // 默认优先5GHz
        spBand.setSelection(Math.min(bandIdx, 4));
    }

    private void saveConfig() {
        SharedPreferences.Editor e = sp.edit();
        e.putString("portalUrl", etPortal.getText().toString().trim());
        e.putString("ssid", etSsid.getText().toString().trim());
        e.putString("username", etUser.getText().toString().trim());
        e.putString("password", etPass.getText().toString());
        e.putString("service", etService.getText().toString().trim());
        e.putString("updateUrl", etUpdateUrl.getText().toString().trim());
        e.putInt("bandPref", spBand.getSelectedItemPosition());
        e.apply();
    }

    private String getCfg(String key, String def) {
        return sp.getString(key, def);
    }

    private int getBandPref() {
        return sp.getInt("bandPref", 1);
    }

    private void appendLog(String msg) {
        runOnUiThread(() -> {
            tvLog.append(msg + "\n");
            svLog.post(() -> svLog.fullScroll(View.FOCUS_DOWN));
        });
    }

    private void requestPermissions() {
        List<String> perms = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 33) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
                perms.add(Manifest.permission.NEARBY_WIFI_DEVICES);
            }
        } else {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                perms.add(Manifest.permission.ACCESS_FINE_LOCATION);
            }
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                && Build.VERSION.SDK_INT >= 33) {
            perms.add(Manifest.permission.POST_NOTIFICATIONS);
        }
        if (!perms.isEmpty()) {
            ActivityCompat.requestPermissions(this, perms.toArray(new String[0]), PERM_REQ);
        }
    }

    // ========== WiFi 连接（按频段选择） ==========

    private void connectWifi() {
        String ssid = getCfg("ssid", "CQRK");
        int band = getBandPref();
        String[] bandNames = {"自动", "优先5GHz", "仅5GHz", "优先2.4GHz", "仅2.4GHz"};
        appendLog("目标WiFi：" + ssid + "，频段偏好：" + bandNames[band]);

        if (!wifiManager.isWifiEnabled()) {
            appendLog("WiFi未开启，正在打开...");
            wifiManager.setWifiEnabled(true);
            try { Thread.sleep(2000); } catch (InterruptedException ignored) {}
        }

        // 检查是否已经连了目标WiFi
        String current = getCurrentSsid();
        if (current != null && current.replace("\"", "").startsWith(ssid)) {
            appendLog("已连接：" + current + "（频段：" + getCurrentBand() + "）");
            return;
        }

        // 扫描
        appendLog("正在扫描WiFi...");
        wifiManager.startScan();
        try { Thread.sleep(3000); } catch (InterruptedException ignored) {}

        List<ScanResult> results = wifiManager.getScanResults();
        List<ScanResult> target = new ArrayList<>();
        for (ScanResult sr : results) {
            if (sr.SSID != null && sr.SSID.equals(ssid)) {
                target.add(sr);
            }
        }

        if (target.isEmpty()) {
            appendLog("未扫描到 " + ssid + "（Android 12+ 需开启位置权限和GPS）");
            appendLog("请手动连接 " + ssid + "，APP 将自动检测...");
            // 轮询等待用户手动连接，最多30秒
            for (int i = 0; i < 15; i++) {
                try { Thread.sleep(2000); } catch (InterruptedException ignored) {}
                String cur = getCurrentSsid();
                if (cur != null && cur.replace("\"", "").startsWith(ssid)) {
                    appendLog("检测到已手动连接：" + cur + "（频段：" + getCurrentBand() + "）");
                    return;
                }
                if (i % 3 == 2) appendLog("等待手动连接中...（" + (i*2) + "秒）");
            }
            appendLog("超时未检测到连接，请手动连接 " + ssid + " 后重新点击连接");
            return;
        }

        appendLog("扫描到 " + target.size() + " 个 " + ssid + " 接入点");

        // 按频段筛选
        ScanResult chosen = pickByBand(target, band);
        if (chosen == null) {
            appendLog("按频段偏好未找到合适的接入点");
            return;
        }

        String bandLabel = is5GHz(chosen.frequency) ? "5GHz" : "2.4GHz";
        appendLog("选择接入点：" + chosen.BSSID + "（" + bandLabel + "，信号 " + chosen.level + "dBm）");

        // 连接
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            connectWifiAndroid10(chosen.SSID, chosen.BSSID);
        } else {
            connectWifiLegacy(chosen.SSID, chosen.BSSID);
        }
    }

    private ScanResult pickByBand(List<ScanResult> list, int band) {
        List<ScanResult> five = new ArrayList<>();
        List<ScanResult> two = new ArrayList<>();
        for (ScanResult sr : list) {
            if (is5GHz(sr.frequency)) five.add(sr);
            else two.add(sr);
        }
        // 按信号强度排序
        Comparator<ScanResult> byLevel = (a, b) -> Integer.compare(b.level, a.level);
        Collections.sort(five, byLevel);
        Collections.sort(two, byLevel);

        switch (band) {
            case 1: return !five.isEmpty() ? five.get(0) : (!two.isEmpty() ? two.get(0) : null);
            case 2: return !five.isEmpty() ? five.get(0) : null;
            case 3: return !two.isEmpty() ? two.get(0) : (!five.isEmpty() ? five.get(0) : null);
            case 4: return !two.isEmpty() ? two.get(0) : null;
            default: return !list.isEmpty() ? list.get(0) : null; // 自动：取信号最强
        }
    }

    private boolean is5GHz(int freq) {
        return freq >= 4900 && freq <= 5900;
    }

    private String getCurrentBand() {
        WifiInfo info = wifiManager.getConnectionInfo();
        if (info == null) return "未知";
        int freq = info.getFrequency();
        return is5GHz(freq) ? "5GHz" : "2.4GHz";
    }

    @SuppressWarnings("deprecation")
    private void connectWifiLegacy(String ssid, String bssid) {
        try {
            WifiConfiguration config = new WifiConfiguration();
            config.SSID = "\"" + ssid + "\"";
            config.BSSID = bssid;
            config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE);
            int netId = wifiManager.addNetwork(config);
            if (netId == -1) {
                // 可能已保存，找已有的
                for (WifiConfiguration c : wifiManager.getConfiguredNetworks()) {
                    if (c.SSID != null && c.SSID.equals("\"" + ssid + "\"")) {
                        netId = c.networkId;
                        break;
                    }
                }
            }
            if (netId != -1) {
                wifiManager.disconnect();
                wifiManager.enableNetwork(netId, true);
                wifiManager.reconnect();
                appendLog("已发起连接请求，等待连接...");
                waitForConnection(ssid);
            } else {
                appendLog("连接失败：无法创建网络配置");
            }
        } catch (Exception e) {
            appendLog("连接异常：" + e.getMessage());
        }
    }

    private void connectWifiAndroid10(String ssid, String bssid) {
        try {
            WifiNetworkSpecifier specifier = new WifiNetworkSpecifier.Builder()
                    .setSsid(ssid)
                    .setBssid(android.net.MacAddress.fromString(bssid))
                    .build();

            NetworkRequest request = new NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .setNetworkSpecifier(specifier)
                    .build();

            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            final boolean[] done = {false};

            ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(@NonNull Network network) {
                    super.onAvailable(network);
                    cm.bindProcessToNetwork(network);
                    appendLog("WiFi连接成功！");
                    done[0] = true;
                }

                @Override
                public void onUnavailable() {
                    super.onUnavailable();
                    appendLog("WiFi连接失败或被用户取消");
                    done[0] = true;
                }
            };

            cm.requestNetwork(request, callback);
            appendLog("请在弹出的系统对话框中点击「连接」");

            // 等待30秒
            int waited = 0;
            while (!done[0] && waited < 30) {
                Thread.sleep(1000);
                waited++;
            }
            cm.unregisterNetworkCallback(callback);

        } catch (Exception e) {
            appendLog("连接异常：" + e.getMessage());
        }
    }

    private void waitForConnection(String ssid) {
        for (int i = 0; i < 15; i++) {
            try { Thread.sleep(1000); } catch (InterruptedException ignored) {}
            String cur = getCurrentSsid();
            if (cur != null && cur.replace("\"", "").startsWith(ssid)) {
                appendLog("已连接：" + cur + "（频段：" + getCurrentBand() + "）");
                return;
            }
        }
        appendLog("连接超时，请手动检查WiFi状态");
    }

    private String getCurrentSsid() {
        try {
            WifiInfo info = wifiManager.getConnectionInfo();
            if (info == null || info.getSSID() == null || info.getSSID().equals("<unknown ssid>")) return null;
            return info.getSSID();
        } catch (Exception e) {
            return null;
        }
    }

    // ========== 认证逻辑 ==========

    private void doAuth() {
        String portal = getCfg("portalUrl", "http://10.10.1.188");
        String expectSsid = getCfg("ssid", "CQRK");
        String username = getCfg("username", "");
        String password = getCfg("password", "");
        String service = getCfg("service", "");

        if (TextUtils.isEmpty(username) || TextUtils.isEmpty(password)) {
            appendLog("错误：请先填写账号和密码");
            return;
        }

        String currentSsid = getCurrentSsid();
        appendLog("当前WiFi：" + (currentSsid == null ? "未连接" : currentSsid));
        if (currentSsid == null || !currentSsid.replace("\"", "").startsWith(expectSsid)) {
            appendLog("未连接目标WiFi，先自动连接...");
            connectWifi();
            currentSsid = getCurrentSsid();
            if (currentSsid == null || !currentSsid.replace("\"", "").startsWith(expectSsid)) {
                // 读不到SSID但可能已连接（Android 12+权限问题），尝试探测门户
                appendLog("未检测到目标WiFi，尝试探测校园网门户...");
                String probe = httpGet(portal + "/", 5, true);
                if (probe != null && (probe.contains("eportal") || probe.contains("index.jsp") || probe.contains("InterFace"))) {
                    appendLog("探测到校园网门户，继续认证");
                } else {
                    appendLog("连接失败，请手动连接校园网后再试");
                    return;
                }
            }
        }

        if (testInternet()) {
            appendLog("外网已通，无需认证");
            return;
        }
        appendLog("外网不通，准备认证...");

        String state = getPortalState(portal);
        appendLog("门户状态：" + state);

        if ("online".equals(state)) {
            appendLog("门户显示已在线但外网不通，尝试登出后重新认证...");
            String userIndex = getUserIndex(portal);
            if (userIndex != null) {
                httpGet(portal + "/eportal/InterFace.do?method=logout&userIndex=" + userIndex, 8, false);
                try { Thread.sleep(2000); } catch (InterruptedException ignored) {}
                appendLog("已执行登出");
            }
            state = "login";
        }

        if (!"login".equals(state)) {
            appendLog("门户不可达，跳过");
            return;
        }

        String qs = getQueryString(portal);
        if (qs == null) {
            appendLog("未能获取认证参数，跳过");
            return;
        }
        appendLog("已获取认证参数（长度 " + qs.length() + "）");

        appendLog("登录账号：" + username + "  运营商：" + (TextUtils.isEmpty(service) ? "未指定" : service));
        String result = doLogin(portal, username, password, service, qs);
        appendLog("登录结果：" + result);

        if ("success".equals(result)) {
            try { Thread.sleep(3000); } catch (InterruptedException ignored) {}
            if (testInternet()) {
                appendLog("验证通过：校园网认证成功，已恢复上网！");
            } else {
                appendLog("登录成功但外网仍不通，请稍候重试");
            }
        } else {
            appendLog("认证失败，请检查账号密码");
        }
    }

    private boolean testInternet() {
        try {
            HttpURLConnection conn = (HttpURLConnection) new URL("http://www.baidu.com").openConnection();
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(5000);
            conn.setInstanceFollowRedirects(false);
            int code = conn.getResponseCode();
            conn.disconnect();
            return code == 200 || code == 301 || code == 302 || code == 304;
        } catch (Exception e) {
            return false;
        }
    }

    private String getPortalState(String portal) {
        try {
            String body = httpGet(portal + "/", 10, true);
            if (body == null) return "unreachable";
            if (body.contains("success.jsp") || body.contains("您已成功连接") || body.contains("下线")) {
                return "online";
            }
            if (body.contains("index.jsp") || body.contains("连接 Login") || body.contains("password") || body.contains("userId")) {
                return "login";
            }
            return "login";
        } catch (Exception e) {
            return "unreachable";
        }
    }

    private String getQueryString(String portal) {
        try {
            HttpURLConnection conn = (HttpURLConnection) new URL(portal + "/").openConnection();
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(10000);
            conn.setInstanceFollowRedirects(false);
            int maxHop = 5;
            while (maxHop-- > 0) {
                int code = conn.getResponseCode();
                if (code == 301 || code == 302) {
                    String location = conn.getHeaderField("Location");
                    if (location != null && location.contains("index.jsp?")) {
                        int idx = location.indexOf("index.jsp?");
                        conn.disconnect();
                        return location.substring(idx + "index.jsp?".length());
                    }
                    conn.disconnect();
                    String nextUrl = location;
                    if (nextUrl.startsWith("/")) nextUrl = portal + nextUrl;
                    conn = (HttpURLConnection) new URL(nextUrl).openConnection();
                    conn.setConnectTimeout(10000);
                    conn.setReadTimeout(10000);
                    conn.setInstanceFollowRedirects(false);
                } else {
                    break;
                }
            }
            conn.disconnect();

            String body = httpGet(portal + "/eportal/redirectortosuccess.jsp", 10, true);
            if (body != null) {
                int idx = body.indexOf("index.jsp?");
                if (idx >= 0) {
                    int end = idx;
                    while (end < body.length() && body.charAt(end) != '"' && body.charAt(end) != '\'' && body.charAt(end) != ' ' && body.charAt(end) != '\n') {
                        end++;
                        if (end - idx > 500) break;
                    }
                    return body.substring(idx + "index.jsp?".length(), end);
                }
            }
        } catch (Exception ignored) {}
        return null;
    }

    private String getUserIndex(String portal) {
        try {
            HttpURLConnection conn = (HttpURLConnection) new URL(portal + "/eportal/redirectortosuccess.jsp").openConnection();
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(10000);
            conn.setInstanceFollowRedirects(false);
            int code = conn.getResponseCode();
            if (code == 301 || code == 302) {
                String location = conn.getHeaderField("Location");
                conn.disconnect();
                if (location != null && location.contains("userIndex=")) {
                    int idx = location.indexOf("userIndex=") + "userIndex=".length();
                    int end = idx;
                    while (end < location.length() && location.charAt(end) != '&' && location.charAt(end) != ' ') end++;
                    return location.substring(idx, end);
                }
            }
            conn.disconnect();
        } catch (Exception ignored) {}
        return null;
    }

    private String doLogin(String portal, String user, String pass, String service, String qs) {
        try {
            String body = "userId=" + urlEncode(user) +
                    "&password=" + urlEncode(pass) +
                    "&service=" + urlEncode(service) +
                    "&queryString=" + urlEncode(qs) +
                    "&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false";

            HttpURLConnection conn = (HttpURLConnection) new URL(portal + "/eportal/InterFace.do?method=login").openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            conn.setRequestProperty("User-Agent", "Mozilla/5.0");
            conn.setRequestProperty("Referer", portal + "/eportal/index.jsp");

            try (OutputStream os = conn.getOutputStream()) {
                os.write(body.getBytes(StandardCharsets.UTF_8));
            }

            InputStream is = conn.getResponseCode() >= 400 ? conn.getErrorStream() : conn.getInputStream();
            BufferedReader reader = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) sb.append(line);
            reader.close();
            conn.disconnect();

            String resp = sb.toString();
            if (resp.contains("\"result\"")) {
                int idx = resp.indexOf("\"result\"");
                int colon = resp.indexOf(':', idx);
                int q1 = resp.indexOf('"', colon);
                int q2 = resp.indexOf('"', q1 + 1);
                if (q1 >= 0 && q2 > q1) return resp.substring(q1 + 1, q2);
            }
            return resp;
        } catch (Exception e) {
            return "异常：" + e.getMessage();
        }
    }

    private String httpGet(String urlStr, int timeout, boolean followRedirects) {
        try {
            HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
            conn.setConnectTimeout(timeout * 1000);
            conn.setReadTimeout(timeout * 1000);
            conn.setInstanceFollowRedirects(followRedirects);
            conn.setRequestProperty("User-Agent", "Mozilla/5.0");
            InputStream is = conn.getResponseCode() >= 400 ? conn.getErrorStream() : conn.getInputStream();
            BufferedReader reader = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) sb.append(line).append("\n");
            reader.close();
            conn.disconnect();
            return sb.toString();
        } catch (Exception e) {
            return null;
        }
    }

    private String urlEncode(String s) {
        try {
            return URLEncoder.encode(URLEncoder.encode(s, "UTF-8"), "UTF-8");
        } catch (Exception e) {
            return "";
        }
    }

    // ========== 检查更新 ==========
    private void checkUpdate() {
        String updateUrl = etUpdateUrl.getText().toString().trim();
        if (TextUtils.isEmpty(updateUrl)) {
            appendLog("请先填写更新地址（version.json 的 URL）");
            return;
        }
        appendLog("正在检查更新...");
        try {
            String json = httpGet(updateUrl, 10, true);
            if (json == null) {
                appendLog("检查更新失败：无法访问更新地址");
                return;
            }
            JSONObject obj = new JSONObject(json);
            int latestCode = obj.optInt("versionCode", 0);
            String latestName = obj.optString("versionName", "");
            String apkUrl = obj.optString("apkUrl", "");
            String changelog = obj.optString("changelog", "");

            PackageInfo pInfo = getPackageManager().getPackageInfo(getPackageName(), 0);
            int currentCode = pInfo.versionCode;
            String currentName = pInfo.versionName;

            appendLog("当前版本：" + currentName + "（" + currentCode + "）");
            appendLog("最新版本：" + latestName + "（" + latestCode + "）");

            if (latestCode > currentCode) {
                appendLog("发现新版本！更新内容：" + changelog);
                if (!TextUtils.isEmpty(apkUrl)) {
                    appendLog("开始下载新版本...");
                    downloadAndInstall(apkUrl);
                } else {
                    appendLog("更新地址未配置 apkUrl，请手动下载");
                }
            } else {
                appendLog("已是最新版本");
            }
        } catch (Exception e) {
            appendLog("检查更新异常：" + e.getMessage());
        }
    }

    private void downloadAndInstall(String apkUrl) {
        try {
            HttpURLConnection conn = (HttpURLConnection) new URL(apkUrl).openConnection();
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(60000);
            conn.setRequestProperty("User-Agent", "Mozilla/5.0");
            InputStream is = conn.getInputStream();

            File dir = new File(getExternalFilesDir(null), "updates");
            if (!dir.exists()) dir.mkdirs();
            File apkFile = new File(dir, "update.apk");
            FileOutputStream fos = new FileOutputStream(apkFile);

            byte[] buffer = new byte[8192];
            int len;
            long total = 0;
            while ((len = is.read(buffer)) != -1) {
                fos.write(buffer, 0, len);
                total += len;
                if (total % (500 * 1024) < 8192) {
                    final long mb = total / 1024 / 1024;
                    runOnUiThread(() -> appendLog("已下载 " + mb + " MB..."));
                }
            }
            fos.close();
            is.close();
            conn.disconnect();

            appendLog("下载完成：" + (total / 1024 / 1024) + " MB，正在安装...");
            installApk(apkFile);
        } catch (Exception e) {
            appendLog("下载失败：" + e.getMessage());
        }
    }

    private void installApk(File apkFile) {
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW);
            Uri uri;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                uri = FileProvider.getUriForFile(this, getPackageName() + ".fileprovider", apkFile);
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            } else {
                uri = Uri.fromFile(apkFile);
            }
            intent.setDataAndType(uri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
            appendLog("已调起安装界面，请确认安装");
        } catch (Exception e) {
            appendLog("安装失败：" + e.getMessage());
        }
    }
}
