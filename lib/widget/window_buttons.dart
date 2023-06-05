import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'package:vup/app.dart';

class WindowButtons extends StatelessWidget {
  const WindowButtons({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return SizedBox();
    }
    return Row(
      children: [
        MinimizeWindowButton(
          colors: WindowButtonColors(
            iconNormal: Theme.of(context).colorScheme.secondary,
          ),
        ),
        MaximizeWindowButton(
          colors: WindowButtonColors(
            iconNormal: Theme.of(context).colorScheme.secondary,
          ),
        ),
        CloseWindowButton(
          colors: WindowButtonColors(
            iconNormal: Theme.of(context).colorScheme.secondary,
          ),
          onPressed: () {
            isAppWindowVisible = false;
            appWindow.hide();
          },
        ),
      ],
    );
  }
}
