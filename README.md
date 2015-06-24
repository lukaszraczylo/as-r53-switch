# AWS Route53 maintenance switch
DNS based failover for AWS Route 53

# Usage:
You need following variables exported:

```
export AWS_ACCESS_KEY_ID=''
export AWS_SECRET_ACCESS_KEY=''
```

# Running:

```
./r53-switch.rb --domain potato.com --record my-test
```