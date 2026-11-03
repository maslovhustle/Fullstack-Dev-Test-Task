import { Link, useRouter } from "@tanstack/react-router"
import { ShieldX } from "lucide-react"

import { Button } from "@/components/ui/button"

const AccessDenied = () => {
  const router = useRouter()

  return (
    <div
      className="flex flex-col items-center justify-center text-center py-16"
      data-testid="access-denied"
    >
      <div className="rounded-full bg-muted p-4 mb-4">
        <ShieldX className="h-8 w-8 text-muted-foreground" />
      </div>
      <h1 className="text-2xl font-bold tracking-tight">Access denied</h1>
      <p className="text-muted-foreground mt-2 max-w-md">
        You don't have permission to view this page. If you think you should,
        contact an administrator.
      </p>
      <div className="flex gap-3 mt-6">
        <Button asChild>
          <Link to="/">Go to dashboard</Link>
        </Button>
        <Button variant="outline" onClick={() => router.history.back()}>
          Go back
        </Button>
      </div>
    </div>
  )
}

export default AccessDenied
