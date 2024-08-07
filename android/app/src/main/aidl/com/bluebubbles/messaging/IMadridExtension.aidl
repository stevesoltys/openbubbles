// IMadridExtension.aidl
package com.bluebubbles.messaging;

import android.widget.RemoteViews;
import com.bluebubbles.messaging.IViewUpdateCallback;
import com.bluebubbles.messaging.IKeyboardHandle;
import com.bluebubbles.messaging.MadridMessage;
import com.bluebubbles.messaging.IMessageViewHandle;

// Declare any non-default types here with import statements

interface IMadridExtension {
    RemoteViews keyboardOpened(in IViewUpdateCallback callback, in IKeyboardHandle handle);
    void keyboardClosed();

    void didTapTemplate(in MadridMessage message, in IMessageViewHandle handle);

    RemoteViews getLiveView(in IViewUpdateCallback callback, in MadridMessage message, in IMessageViewHandle handle);
    void messageUpdated(in MadridMessage message);
}