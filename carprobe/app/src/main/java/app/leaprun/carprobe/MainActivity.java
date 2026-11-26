package app.leaprun.carprobe;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.ByteBuffer;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * 车机探针：只回答四个问题，不抓正式的业务逻辑。
 *
 * 1. 这台车机能不能装、能不能跑第三方 APK（装上了就是在跑）
 * 2. MediaProjection 能不能拿到屏幕画面（能，才有「抓 360 画面」的可能）
 * 3. 能不能读 logcat（很多车况信号在车机上只走日志）
 * 4. 车机能不能连到手机（热点）并 POST 一张图
 *
 * 结果会同时写到 getExternalFilesDir 下的 probe.txt，路径显示在界面上。
 * 界面用纯 framework 控件，不引 AndroidX——老车机上的兼容性问题最少。
 */
public class MainActivity extends Activity {

    private static final int REQ_CAPTURE = 1001;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final StringBuilder log = new StringBuilder();

    private TextView output;
    private ImageView preview;
    private EditText hostInput;

    private MediaProjection projection;
    private VirtualDisplay display;
    private ImageReader reader;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildUi());
        append("LeapProbe 启动 " + now());
        append("设备：" + Build.MANUFACTURER + " " + Build.MODEL + " / Android " + Build.VERSION.RELEASE
                + " (API " + Build.VERSION.SDK_INT + ")");
        append("应用目录：" + getExternalFilesDir(null));
        append("");
        append("请依次点下面五个按钮，最后一个把结果发我。");
    }

    private View buildUi() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root);

        root.addView(button("1. 列出相机 / 360 相关的应用", v -> listCameraPackages()));
        root.addView(button("2. 截屏测试（会弹系统授权）", v -> requestCapture()));
        root.addView(button("3. logcat 测试", v -> testLogcat()));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        hostInput = new EditText(this);
        hostInput.setHint("手机 IP:端口，例如 192.168.43.1:8000");
        hostInput.setText("192.168.43.1:8000");
        hostInput.setSingleLine(true);
        row.addView(hostInput, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        row.addView(button("4. 连手机", v -> testNetwork()));
        root.addView(row);

        root.addView(button("5. 保存结果并显示路径", v -> dumpResult()));

        preview = new ImageView(this);
        preview.setAdjustViewBounds(true);
        preview.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(220)));
        root.addView(preview);

        output = new TextView(this);
        output.setTextSize(12);
        output.setTextIsSelectable(true);
        output.setPadding(0, dp(12), 0, 0);
        root.addView(output);

        return scroll;
    }

    private Button button(String text, View.OnClickListener onClick) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setOnClickListener(onClick);
        b.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        return b;
    }

    // MARK: - 1. 相机 / 360 应用

    private void listCameraPackages() {
        append("");
        append("== 相机 / 360 相关应用 ==");
        List<String> keys = new ArrayList<>();
        keys.add("avm");
        keys.add("camera");
        keys.add("pano");
        keys.add("surround");
        keys.add("360");
        keys.add("park");
        keys.add("dvr");
        keys.add("dash");
        keys.add("adas");

        int found = 0;
        for (ApplicationInfo info : getPackageManager().getInstalledApplications(PackageManager.GET_META_DATA)) {
            String name = info.packageName;
            String lower = name.toLowerCase(Locale.ROOT);
            for (String key : keys) {
                if (lower.contains(key)) {
                    boolean system = (info.flags & ApplicationInfo.FLAG_SYSTEM) != 0;
                    append("  " + name + (system ? "（系统）" : ""));
                    found++;
                    break;
                }
            }
        }
        if (found == 0) append("  没找到。可能是系统应用对 PackageManager 隐藏了。");
        append("  共 " + found + " 个");
    }

    // MARK: - 2. 截屏

    private void requestCapture() {
        MediaProjectionManager manager =
                (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        if (manager == null) {
            append("");
            append("== 截屏 == 系统没有 MediaProjection 服务，这条路断了。");
            return;
        }
        try {
            startActivityForResult(manager.createScreenCaptureIntent(), REQ_CAPTURE);
            append("");
            append("== 截屏 == 已弹出授权，请看车机屏幕。");
        } catch (Exception e) {
            append("");
            append("== 截屏 == 拉起授权失败：" + e);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_CAPTURE) return;
        if (resultCode != RESULT_OK || data == null) {
            append("  授权被拒绝（resultCode=" + resultCode + "）");
            return;
        }
        try {
            MediaProjectionManager manager =
                    (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            projection = manager.getMediaProjection(resultCode, data);
            startMirror();
            append("  授权通过，正在抓一帧……");
        } catch (Exception e) {
            append("  启动截屏失败：" + e);
        }
    }

    private void startMirror() {
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        int width = metrics.widthPixels;
        int height = metrics.heightPixels;
        int density = metrics.densityDpi;

        reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2);
        display = projection.createVirtualDisplay(
                "leap-probe", width, height, density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader.getSurface(), null, main);

        main.postDelayed(() -> {
            try {
                Image image = reader.acquireLatestImage();
                if (image == null) {
                    append("  没抓到帧：虚拟屏可能被系统拦了。");
                    return;
                }
                Bitmap bitmap = toBitmap(image, width, height);
                image.close();
                preview.setImageBitmap(bitmap);
                File out = new File(getExternalFilesDir(null), "shot.png");
                try (FileOutputStream fos = new FileOutputStream(out)) {
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos);
                }
                append("  抓到了！保存到 " + out.getAbsolutePath()
                        + "（" + bitmap.getWidth() + "×" + bitmap.getHeight() + "）");
            } catch (Exception e) {
                append("  抓帧出错：" + e);
            } finally {
                stopMirror();
            }
        }, 800);
    }

    private Bitmap toBitmap(Image image, int width, int height) {
        Image.Plane plane = image.getPlanes()[0];
        ByteBuffer buffer = plane.getBuffer();
        int pixelStride = plane.getPixelStride();
        int rowStride = plane.getRowStride();
        int rowPadding = rowStride - pixelStride * width;
        Bitmap bitmap = Bitmap.createBitmap(width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888);
        bitmap.copyPixelsFromBuffer(buffer);
        return Bitmap.createBitmap(bitmap, 0, 0, width, height);
    }

    private void stopMirror() {
        if (display != null) display.release();
        if (reader != null) reader.close();
        if (projection != null) projection.stop();
        display = null;
        reader = null;
        projection = null;
    }

    // MARK: - 3. logcat

    private void testLogcat() {
        append("");
        append("== logcat ==");
        try {
            Process process = Runtime.getRuntime().exec(new String[]{"logcat", "-d", "-t", "60"});
            BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()));
            String first = reader.readLine();
            String second = reader.readLine();
            process.waitFor();
            if (first == null) {
                append("  读不到任何行（大概被拒了）。");
            } else {
                append("  能读！前两行：");
                append("  " + first);
                if (second != null) append("  " + second);
            }
            BufferedReader err = new BufferedReader(new InputStreamReader(process.getErrorStream()));
            String line = err.readLine();
            if (line != null) append("  stderr: " + line);
        } catch (Exception e) {
            append("  执行失败：" + e);
        }
    }

    // MARK: - 4. 网络

    private void testNetwork() {
        String host = hostInput.getText().toString().trim();
        append("");
        append("== 连手机 == " + host);
        new Thread(() -> {
            HttpURLConnection connection = null;
            try {
                URL url = new URL("http://" + host + "/probe");
                connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(4000);
                connection.setReadTimeout(4000);
                connection.setRequestMethod("POST");
                connection.setDoOutput(true);
                try (OutputStream os = connection.getOutputStream()) {
                    os.write(("hello from car " + now()).getBytes("UTF-8"));
                }
                int code = connection.getResponseCode();
                post(() -> append("  连上了，HTTP " + code + "。手机侧收到就说明通路成立。"));
            } catch (Exception e) {
                post(() -> append("  连不上：" + e));
            } finally {
                if (connection != null) connection.disconnect();
            }
        }).start();
    }

    private void post(Runnable runnable) {
        main.post(runnable);
    }

    // MARK: - 5. 输出

    private void dumpResult() {
        File out = new File(getExternalFilesDir(null), "probe.txt");
        try (FileOutputStream fos = new FileOutputStream(out)) {
            fos.write(log.toString().getBytes("UTF-8"));
            append("");
            append("已保存：" + out.getAbsolutePath());
            Toast.makeText(this, "已保存到 " + out.getAbsolutePath(), Toast.LENGTH_LONG).show();
        } catch (Exception e) {
            append("保存失败：" + e);
        }
    }

    private void append(String line) {
        log.append(line).append('\n');
        if (output != null) output.setText(log.toString());
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private String now() {
        return new SimpleDateFormat("MM-dd HH:mm:ss", Locale.ROOT).format(new Date());
    }
}
