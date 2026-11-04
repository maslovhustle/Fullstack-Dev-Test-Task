import { zodResolver } from "@hookform/resolvers/zod"
import { useMutation } from "@tanstack/react-query"
import { createFileRoute } from "@tanstack/react-router"
import { useForm } from "react-hook-form"
import { z } from "zod"

import { Permission, UtilsService } from "@/client"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form"
import { Input } from "@/components/ui/input"
import { LoadingButton } from "@/components/ui/loading-button"
import useAuth from "@/hooks/useAuth"
import useCustomToast from "@/hooks/useCustomToast"
import { requirePermission } from "@/lib/permissions"
import { handleError } from "@/utils"

const formSchema = z.object({
  email_to: z.email({ message: "Invalid email address" }),
})

type FormData = z.infer<typeof formSchema>

export const Route = createFileRoute("/_layout/system")({
  component: System,
  beforeLoad: requirePermission(Permission.SETTINGS_MANAGE),
  head: () => ({
    meta: [
      {
        title: "System - FastAPI Template",
      },
    ],
  }),
})

function TestEmailForm() {
  const { user: currentUser } = useAuth()
  const { showSuccessToast, showErrorToast } = useCustomToast()

  const form = useForm<FormData>({
    resolver: zodResolver(formSchema),
    mode: "onBlur",
    criteriaMode: "all",
    defaultValues: {
      email_to: currentUser?.email ?? "",
    },
  })

  const mutation = useMutation({
    mutationFn: (data: FormData) => UtilsService.testEmail({ query: data }),
    onSuccess: () => {
      showSuccessToast("Test email sent")
    },
    onError: handleError.bind(showErrorToast),
  })

  const onSubmit = (data: FormData) => {
    mutation.mutate(data)
  }

  return (
    <Form {...form}>
      <form
        onSubmit={form.handleSubmit(onSubmit)}
        className="flex flex-col gap-4"
      >
        <FormField
          control={form.control}
          name="email_to"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Recipient</FormLabel>
              <FormControl>
                <Input
                  data-testid="test-email-input"
                  placeholder="Email"
                  type="email"
                  {...field}
                  required
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <LoadingButton
          type="submit"
          loading={mutation.isPending}
          className="self-start"
        >
          Send test email
        </LoadingButton>
      </form>
    </Form>
  )
}

function System() {
  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">System settings</h1>
        <p className="text-muted-foreground">
          Check and maintain system configuration
        </p>
      </div>
      <Card className="max-w-md">
        <CardHeader>
          <CardTitle>Email delivery</CardTitle>
          <CardDescription>
            Send a test email to verify the SMTP configuration.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <TestEmailForm />
        </CardContent>
      </Card>
    </div>
  )
}
