! Deployment configuration for the test-only conformance adapter.
!
! The Docker build copies this file into the adapter vocabulary's directory
! as deploy.factor, which is where Factor's deploy tool looks for it. Keeping
! it under client/ leaves the educational repository free of a toolchain
! directory layout.
!
! deploy-reflection stays at 2 so the client's own error classes and their
! accessors survive stripping and can still explain a failure. The dictionary
! and word definitions are stripped, so the deployed binary carries no
! interactive compiler surface. C types are retained because the OpenSSL
! bindings under TLS need them at run time.

USING: tools.deploy.config ;

H{
    { deploy-name "convex-adapter" }
    { deploy-c-types? t }
    { deploy-console? t }
    { deploy-help? f }
    { deploy-io 3 }
    { deploy-math? t }
    { deploy-reflection 2 }
    { deploy-threads? t }
    { deploy-ui? f }
    { deploy-unicode? t }
    { deploy-word-defs? f }
    { deploy-word-props? f }
}
