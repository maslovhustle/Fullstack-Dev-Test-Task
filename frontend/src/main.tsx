import {
  MutationCache,
  QueryCache,
  QueryClient,
  QueryClientProvider,
  type QueryKey,
} from "@tanstack/react-query"
import { createRouter, RouterProvider } from "@tanstack/react-router"
import { StrictMode } from "react"
import ReactDOM from "react-dom/client"
import { client } from "./client/client.gen"
import AccessDenied from "./components/Common/AccessDenied"
import ErrorComponent from "./components/Common/ErrorComponent"
import { ThemeProvider } from "./components/theme-provider"
import { Toaster } from "./components/ui/sonner"
import { currentUserQueryOptions } from "./hooks/useAuth"
import "./index.css"
import { apiErrorAction, shouldRetryQuery } from "./lib/api-errors"
import { isForbiddenError } from "./lib/permissions"
import { routeTree } from "./routeTree.gen"

client.setConfig({
  baseURL: import.meta.env.VITE_API_URL ?? "",
  auth: () => localStorage.getItem("access_token") || "",
})

const handleApiError = (error: Error, queryKey?: QueryKey) => {
  const action = apiErrorAction(error, queryKey)
  if (action === "logout") {
    localStorage.removeItem("access_token")
    window.location.href = "/login"
  } else if (action === "refresh-permissions") {
    queryClient.invalidateQueries({
      queryKey: currentUserQueryOptions.queryKey,
    })
  }
}
const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: shouldRetryQuery },
  },
  queryCache: new QueryCache({
    onError: (error, query) => handleApiError(error, query.queryKey),
  }),
  mutationCache: new MutationCache({
    onError: (error) => handleApiError(error),
  }),
})

const router = createRouter({
  routeTree,
  context: { queryClient },
  defaultErrorComponent: ({ error }) =>
    isForbiddenError(error) ? <AccessDenied /> : <ErrorComponent />,
})
declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router
  }
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ThemeProvider defaultTheme="dark" storageKey="vite-ui-theme">
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
        <Toaster richColors closeButton />
      </QueryClientProvider>
    </ThemeProvider>
  </StrictMode>,
)
