# SoundSeen
SoundSeen: Project Plan
Team BENEV: Benson Vo, Vincent Liu, Edward Lee, Nicole Zhou, Evan Chang

## Description
SoundSeen is a mobile accessibility app that translates music into a multi-sensory experience. It uses real-time audio analysis to convert musical elements (emotion, intensity, and structure) into dynamic visuals and synchronized haptic feedback.

## Problem
Traditional music accessibility for the Deaf and Hard-of-Hearing (DHH) community is largely limited to text-based lyrics. Captions and existing apps fail to communicate the energy of a song—the tension of a buildup, the impact of a bass drop, or the emotional shift of a bridge.

## Why
Music is more than just lyrics; it is a physical and emotional arc. By mapping acoustic data to visual and tactile sensations, we provide users with the ability to "feel" and "see" the nuance of music in a live environment, moving beyond static text to a visceral experience.

## Success Criteria
Real-time Processing: Seamless streaming of music into visual and tactile representations with sub-50ms latency.

Emotional Accuracy: The AI accurately maps the "vibe" (valence/arousal) of the track to the output.

Engagement: DHH users find the multi-sensory feedback intuitive and immersive.

## Audience
Deaf and Hard-of-Hearing (DHH) community.

Users with sensory processing preferences.

## Scope of Work
Must-Have Features (P0)
Local File Interpretation: User can upload a song (MP3/AAC) to be interpreted in real-time.

Tactile Textures: Haptic feedback using varying frequencies and intensities via the Taptic Engine.

Audio-Reactive Visuals: A dynamic visualizer that responds to frequency, amplitude, and mood.

Structured HUD: A dashboard for users to adjust haptic strength and visual sensitivity.

Library Management: Basic UI to store and access previously processed tracks.

Should-Have & Nice-to-Have (P1/P2)
P1 - Live Microphone Input: Real-time "transcription" of ambient music (concerts, clubs).

P2 - Streaming Integration: Synchronizing visuals/haptics with external apps like Spotify/Apple Music.

## Technologies
Frontend: Swift / SwiftUI

Audio Engine: AVAudioEngine & Accelerate Framework (vDSP) for high-performance, real-time FFT.

Haptics: Core Haptics API (creating .ahap haptic patterns).

AI/Inference: Core ML (on-device emotion and structural classification).

Database: SwiftData (local persistence for settings and metadata).

## Deliverables
Functional iOS App: A production-ready build distributed via TestFlight.

Core Haptic Library: A curated set of custom .ahap files representing different musical "textures" (e.g., sharp percussion vs. smooth bass).

Real-time DSP Engine: A standalone Swift module that processes 20ms audio buffers into sensation parameters.

## Out of Scope
Social Ecosystem: No followers, following lists, or social feeds/comments.

Cross-Platform: No Android support (MVP is optimized for Apple’s Taptic Engine).

External Hardware: No support for wearable haptic vests or Bluetooth-connected haptic devices.

Video Export: No feature to record and export the visualizations as video files.
