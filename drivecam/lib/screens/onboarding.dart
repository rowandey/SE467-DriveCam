import 'package:drivecam/widgets/app_bars/app_bar.dart';
import 'package:drivecam/widgets/app_bars/bottom_app_bar.dart';
import 'package:flutter/material.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      appBar: MyAppBar(title: 'Onboarding'),
      body: Center(child: Text('Onboarding')),
      bottomNavigationBar: MyBottomNavBar(),
    );
  }
}
