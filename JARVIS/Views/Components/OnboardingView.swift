// JARVIS - OnboardingView.swift
// First-time setup experience

import SwiftUI

struct OnboardingView: View {
    @State private var currentPage = 0
    @Binding var hasCompletedOnboarding: Bool

    var body: some View {
        ZStack {
            AnimatedBackground()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    WelcomePage().tag(0)
                    FeaturesPage().tag(1)
                    SetupPage().tag(2)
                    GetStartedPage(hasCompletedOnboarding: $hasCompletedOnboarding).tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)

                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(currentPage == index ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .scaleEffect(currentPage == index ? 1.2 : 1.0)
                            .animation(.spring(response: 0.3), value: currentPage)
                    }
                }
                .padding(.bottom, 20)

                HStack {
                    if currentPage > 0 {
                        Button("Back") {
                            withAnimation { currentPage -= 1 }
                        }
                        .foregroundColor(.white.opacity(0.7))
                    }

                    Spacer()

                    if currentPage < 3 {
                        Button {
                            withAnimation { currentPage += 1 }
                        } label: {
                            HStack {
                                Text("Next")
                                Image(systemName: "arrow.right")
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
    }
}

private struct WelcomePage: View {
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: CGFloat = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: CGFloat(120 + i * 40), height: CGFloat(120 + i * 40))
                        .opacity(logoOpacity * (1 - Double(i) * 0.3))
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: .blue.opacity(0.5), radius: 20)

                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }
            .scaleEffect(logoScale)
            .opacity(logoOpacity)

            VStack(spacing: 8) {
                Text("JARVIS")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)

                Text("Seu assistente. Seu contexto. Suas regras.")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
            .opacity(logoOpacity)

            Spacer()
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
        }
    }
}

private struct FeaturesPage: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("JARVIS")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            VStack(spacing: 24) {
                FeatureRow(
                    icon: "mic.fill",
                    color: .blue,
                    title: "Controle por voz",
                    description: "Diga \"Ok Jarvis\" para ativar e conversar sem usar as mãos."
                )

                FeatureRow(
                    icon: "camera.fill",
                    color: .purple,
                    title: "Contexto visual",
                    description: "Analisa imagens e, quando disponível, o que a câmera está vendo."
                )

                FeatureRow(
                    icon: "bolt.fill",
                    color: .orange,
                    title: "Ferramentas reais",
                    description: "Pesquisa atual, recursos do iPhone e integrações do assistente."
                )

                FeatureRow(
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "Controle do usuário",
                    description: "A frase de ativação define quando a conversa começa."
                )
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 50, height: 50)

                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)

                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

private struct SetupPage: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Configuração rápida")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            VStack(spacing: 20) {
                SetupStep(
                    number: 1,
                    title: "Escolha a IA",
                    description: "Selecione Gemini Live, OpenAI, OpenClaw ou um backend local"
                )

                SetupStep(
                    number: 2,
                    title: "Adicione as credenciais",
                    description: "Configure as chaves ou o gateway necessários em Settings"
                )

                SetupStep(
                    number: 3,
                    title: "Configure o hardware",
                    description: "Use o iPhone e, futuramente, conecte os óculos Meta"
                )

                SetupStep(
                    number: 4,
                    title: "Comece a falar",
                    description: "Diga \"Ok Jarvis\" e faça uma pergunta"
                )
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
    }
}

private struct SetupStep: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Text("\(number)")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)

                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()
        }
    }
}

private struct GetStartedPage: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var buttonScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.green.opacity(0.3), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green, .green.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: .green.opacity(0.5), radius: 20)

                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
            }

            Text("JARVIS pronto")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Configure o backend de IA em Settings e inicie sua primeira conversa.")
                .font(.body)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button {
                withAnimation {
                    hasCompletedOnboarding = true
                }
            } label: {
                Text("Começar")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .shadow(color: .blue.opacity(0.3), radius: 10)
            }
            .scaleEffect(buttonScale)
            .padding(.horizontal, 32)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.5)
                        .repeatForever(autoreverses: true)
                ) {
                    buttonScale = 1.05
                }
            }

            Spacer()
        }
    }
}

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
}
