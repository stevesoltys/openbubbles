import 'dart:math';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';

class ReactionPickerClipper extends CustomClipper<Path>{
  final Size messageSize;
  final bool isFromMe;
  const ReactionPickerClipper({required this.messageSize, required this.isFromMe});

  @override
  Path getClip(Size size) {
    var boxheight = size.height - 15;
    final path = Path();
    path.moveTo(size.width - (boxheight / 2), 0);
    path.arcToPoint(Offset(size.width - (boxheight / 2), boxheight), radius: Radius.circular(boxheight / 2));
    path.lineTo(boxheight / 2, boxheight);
    path.arcToPoint(Offset(boxheight / 2, 0), radius: Radius.circular(boxheight / 2));
    path.lineTo(size.width - (boxheight / 2), 0);
    return path;
  }

  @override
  bool shouldReclip(covariant ReactionPickerClipper oldClipper) {
    return false;
  }
}