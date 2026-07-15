
ALTER TABLE public.product_agents
  ADD COLUMN IF NOT EXISTS voice_mode_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS voice_behavior_prompt text,
  ADD COLUMN IF NOT EXISTS voice_max_sentences smallint NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS voice_max_seconds smallint NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS voice_always_end_with_question boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS voice_show_tools_early boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS voice_max_call_minutes smallint NOT NULL DEFAULT 10;

UPDATE public.product_agents
   SET voice_behavior_prompt = $$Você está em uma LIGAÇÃO DE VOZ. Regras deste canal:
1. Respostas curtas — no máximo 2 frases, nunca mais de ~8s falando.
2. Termine toda fala devolvendo a bola (uma pergunta ou convite à ação).
3. A pessoa deve falar mais que você (meta: 70% ela / 30% você).
4. Nunca liste features. Um benefício por vez, ancorado na dor que ela mencionou.
5. Sem emojis, sem markdown, sem "vou te enviar por escrito" — é fala natural.
6. Conduza cada troca para um desfecho: agendamento, proposta ou qualificação.
7. Ao detectar interesse em agendar, chame `listar_horarios_reuniao` imediatamente — não descreva horários por voz, mostre na tela.
8. Se em {MAX_MIN} minutos não houve avanço, ofereça desfecho alternativo com elegância.$$
 WHERE voice_behavior_prompt IS NULL;
