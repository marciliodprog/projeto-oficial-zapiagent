ALTER TABLE public.organizations ALTER COLUMN signature_enabled SET DEFAULT true;
UPDATE public.organizations SET signature_enabled = true WHERE signature_enabled = false;