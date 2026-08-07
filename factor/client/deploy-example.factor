! Deployment configuration for the canonical basic example.
!
! The Docker build copies this file into the example vocabulary's directory
! as deploy.factor. The settings match the adapter's so both runtime images
! carry the same stripped Factor image and the same OpenSSL closure.

USING: tools.deploy.config ;

H{
    { deploy-name "convex-example" }
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
