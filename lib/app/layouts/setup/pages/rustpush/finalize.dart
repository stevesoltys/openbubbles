import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart' hide Response;

class FinalizePage extends StatefulWidget {
  @override
  State<FinalizePage> createState() => _FinalizePageState();
}

class _FinalizePageState extends OptimizedState<FinalizePage> {
  final controller = Get.find<SetupViewController>();

  List<String> handles = [];

  @override
  void initState() {
    super.initState();
    api.getHandles(state: pushService.state).then((result) {
      setState(() {
        handles = result.map((e) => e.replaceFirst("tel:", "").replaceAll("mailto:", "")).toList();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: "Done!",
      subtitle: "",
      customSubtitle: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "You can be reached on iMessage at",
              style: context.theme.textTheme.bodyLarge!.apply(
                fontSizeDelta: 1.5,
                color: context.theme.colorScheme.outline,
              ).copyWith(height: 2)
            ),
            ...handles.map((e) => Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                e,
                style: context.theme.textTheme.titleMedium,
              ),
            )),
            if (!kIsDesktop)
            const Text(
              "Note: Phone numbers cannot be registered without an iOS device"
            ),
          ],
        ),
      ),
      customButton: Column(
        children: [
          ErrorText(parentController: controller),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: Theme(
                    data: context.theme.copyWith(
                      inputDecorationTheme: InputDecorationTheme(
                        labelStyle: TextStyle(color: context.theme.colorScheme.outline),
                      ),
                    ),
                    child: Column(
                      children: [
                        if (ss.settings.macIsMine.value)
                        const Text(
                          "Share your iMessage access with up to 20 friends in settings!",
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(25),
                                gradient: LinearGradient(
                                  begin: AlignmentDirectional.topStart,
                                  colors: [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
                                ),
                              ),
                              height: 40,
                              child: ElevatedButton(
                                style: ButtonStyle(
                                  shape: MaterialStateProperty.all<RoundedRectangleBorder>(
                                    RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20.0),
                                    ),
                                  ),
                                  backgroundColor: MaterialStateProperty.all(Colors.transparent),
                                  shadowColor: MaterialStateProperty.all(Colors.transparent),
                                  maximumSize: MaterialStateProperty.all(const Size(200, 36)),
                                  minimumSize: MaterialStateProperty.all(const Size(30, 30)),
                                ),
                                onPressed: () async {
                                  connect();
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text("Done",
                                        style: context.theme.textTheme.bodyLarge!
                                            .apply(fontSizeFactor: 1.1, color: Colors.white)),
                                    const SizedBox(width: 10),
                                    const Icon(Icons.check, color: Colors.white, size: 20),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> connect() async {
    Get.offAll(() => ConversationList(
        showArchivedChats: false,
        showUnknownSenders: false,
      ),
      routeName: "",
      duration: Duration.zero,
      transition: Transition.noTransition
    );
    Get.delete<SetupViewController>(force: true);
  }

}