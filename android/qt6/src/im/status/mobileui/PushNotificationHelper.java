package im.status.mobileui;

import android.Manifest;
import android.app.Activity;
import android.app.Fragment;
import android.app.FragmentManager;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;

public class PushNotificationHelper {
    private static final String TAG = "PushNotificationHelper";
    private static final String CHANNEL_ID = "mobileui-messages";
    private static final String CHANNEL_NAME = "Messages";
    private static final int REQUEST_CODE_POST_NOTIFICATIONS = 1001;
    private static final String PREFS_NAME = "push_notification_helper_prefs";
    private static final String KEY_POST_NOTIFICATIONS_REQUESTED_BEFORE = "post_notifications_requested_before";
    private static final String GROUP_KEY_MESSAGES = "mobileui.messages";
    private static final int SUMMARY_NOTIFICATION_ID = 0x4D5549; // 'MUI'
    private static final boolean ENABLE_NOTIFICATION_ACTIONS = true;
    private static final String PERMISSION_FRAGMENT_TAG = "mobileui.permission.fragment";

    private static Context sApplicationContext = null;

    public static void initialize(Context context) {
        if (context != null) {
            sApplicationContext = context.getApplicationContext();
        }
    }

    public static boolean hasNotificationPermission(Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            int result = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            );
            return result == PackageManager.PERMISSION_GRANTED;
        }
        return true;
    }

    public static boolean areNotificationsEnabled(Context context) {
        try {
            return NotificationManagerCompat.from(context).areNotificationsEnabled();
        } catch (Exception ignored) {
            return true;
        }
    }

    private static boolean wasPostNotificationsRequestedBefore(Context context) {
        try {
            SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
            return prefs.getBoolean(KEY_POST_NOTIFICATIONS_REQUESTED_BEFORE, false);
        } catch (Exception ignored) {
            return false;
        }
    }

    private static void markPostNotificationsRequested(Context context) {
        try {
            SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
            prefs.edit().putBoolean(KEY_POST_NOTIFICATIONS_REQUESTED_BEFORE, true).apply();
        } catch (Exception ignored) {
        }
    }

    public static boolean isNotificationPermissionRequestable(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return false;
        }
        if (context == null) return false;
        if (hasNotificationPermission(context)) return false;
        if (!(context instanceof Activity)) return false;

        Activity activity = (Activity) context;
        boolean rationale = ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            Manifest.permission.POST_NOTIFICATIONS
        );
        boolean requestedBefore = wasPostNotificationsRequestedBefore(activity);
        return !requestedBefore || rationale;
    }

    public static void requestNotificationPermission(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return;
        }
        if (!(context instanceof Activity)) return;
        Activity activity = (Activity) context;
        Runnable requestRunnable = () -> {
            PermissionFragment fragment = getOrCreatePermissionFragment(activity);
            if (fragment == null) {
                return;
            }
            markPostNotificationsRequested(activity);
            fragment.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},
                REQUEST_CODE_POST_NOTIFICATIONS);
        };
        if (Looper.myLooper() == Looper.getMainLooper()) {
            requestRunnable.run();
        } else {
            activity.runOnUiThread(requestRunnable);
        }
    }

    public static void openNotificationSettings(Context context) {
        if (context == null) return;
        Intent intent = new Intent();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            intent.setAction(Settings.ACTION_APP_NOTIFICATION_SETTINGS);
            intent.putExtra(Settings.EXTRA_APP_PACKAGE, context.getPackageName());
        } else {
            intent.setAction(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
            intent.setData(Uri.fromParts("package", context.getPackageName(), null));
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(intent);
    }

    public static void onNotificationPermissionResult(boolean granted) {
        try {
            nativeOnNotificationPermissionResult(granted);
        } catch (UnsatisfiedLinkError ignored) {
        }
    }

    public static void showNotification(String title, String message, String identifier) {
        try {
            Context context = getApplicationContext();
            if (context == null) {
                return;
            }
            if (!areNotificationsEnabled(context)) {
                return;
            }
            if (!hasNotificationPermission(context)) {
                return;
            }

            NotificationManagerCompat manager = NotificationManagerCompat.from(context);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_DEFAULT
                );
                manager.createNotificationChannel(channel);
            }

            Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
            PendingIntent pendingIntent = null;
            if (intent != null && ENABLE_NOTIFICATION_ACTIONS) {
                intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
                pendingIntent = PendingIntent.getActivity(
                    context,
                    identifier != null ? identifier.hashCode() : 0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
                );
            }

            NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(context.getApplicationInfo().icon)
                .setContentTitle(title != null ? title : "")
                .setContentText(message != null ? message : "")
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .setGroup(GROUP_KEY_MESSAGES);

            if (pendingIntent != null) {
                builder.setContentIntent(pendingIntent);
            }

            int notificationId = identifier != null ? identifier.hashCode() : (int) System.currentTimeMillis();
            manager.notify(notificationId, builder.build());

            NotificationCompat.Builder summaryBuilder = new NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(context.getApplicationInfo().icon)
                .setContentTitle(CHANNEL_NAME)
                .setGroup(GROUP_KEY_MESSAGES)
                .setGroupSummary(true)
                .setAutoCancel(true);
            manager.notify(SUMMARY_NOTIFICATION_ID, summaryBuilder.build());
        } catch (Exception e) {
            Log.w(TAG, "Failed to show notification", e);
        }
    }

    public static void clearNotifications(String identifier) {
        Context context = getApplicationContext();
        if (context == null) return;
        NotificationManagerCompat manager = NotificationManagerCompat.from(context);
        if (identifier != null && !identifier.isEmpty()) {
            manager.cancel(identifier.hashCode());
        } else {
            manager.cancelAll();
        }
    }

    private static Context getApplicationContext() {
        return sApplicationContext;
    }

    private static native void nativeOnNotificationPermissionResult(boolean granted);

    @SuppressWarnings("deprecation")
    private static PermissionFragment getOrCreatePermissionFragment(Activity activity) {
        if (activity == null || activity.isFinishing()) {
            return null;
        }
        try {
            FragmentManager fragmentManager = activity.getFragmentManager();
            Fragment existing = fragmentManager.findFragmentByTag(PERMISSION_FRAGMENT_TAG);
            if (existing instanceof PermissionFragment) {
                return (PermissionFragment) existing;
            }
            PermissionFragment fragment = new PermissionFragment();
            fragmentManager.beginTransaction()
                .add(fragment, PERMISSION_FRAGMENT_TAG)
                .commitAllowingStateLoss();
            fragmentManager.executePendingTransactions();
            return fragment;
        } catch (Exception ignored) {
            return null;
        }
    }

    @SuppressWarnings("deprecation")
    public static class PermissionFragment extends Fragment {
        @Override
        public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults);
            if (requestCode != REQUEST_CODE_POST_NOTIFICATIONS) {
                return;
            }
            boolean granted = grantResults != null
                && grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            PushNotificationHelper.onNotificationPermissionResult(granted);
        }
    }
}
