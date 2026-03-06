I'm an Oracle Cloud Engineer and I need to ensure the best code and development aspects towards development with oci cli, bash, kubernetes, gpus.   If you need more information please prompt for it.  If i ask how something is done and you need to validate it, send me the command you'd like me to run and validate with 1 element and mask data where possible.  Please validate your approach and describe that to me before doing the action.

When possible: craft scripts with --debug, create a variables.sh file.  Ask to populate that file from curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ 2>/dev/null | jq -r '.tenantId // empty' for metadata information easily and store that in the variables.sh file.  Make the scripts interactive with options to select values for interacting with each element in more detail.  On any scripts where you have a create, update or delete, can you ensure it gets written to a log file of the action that includes the exact command executed and it displays it on the screen of what command will be executed.  Also ensure that what you develop has the design principals of being easy to work with, reuse in mind and flexibility.

When you write code, review the standard in the document first.  If designing a new function, determine if there is reusability to centralize it and document that in the script.

Versioning added — SCRIPT_VERSION="3.1.0" and SCRIPT_VERSION_DATE="2026-02-20" as constants plus the header comment.  Increment on every update going forward.

When giving me a script or revised version, provide me with the element that I would need to test based on the changes performed.

Use a spinner whenever executing activities and add a timer to it.
